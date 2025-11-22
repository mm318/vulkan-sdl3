//! Experimental Vulkan dvui renderer
//! Its not a full backend, only implements rendering related backend functions.
//! All non rendering related functions get forwarded to base_backend (whatever backend is selected through build zig).
//! Should work with any base backend as long as it doesn't break from not receiving some of the overridden callbacks or its not rendering from non rendering related calls.
//! Tested only with sdl3 base backend.
//!
//! Notes:
//! * Currently app must provide vulkan setup, swapchain & present logic, etc.
//! * Param `frames_in_flight`, very important:
//!   Currently renderer itself performs almost no locking with gpu except when creating new textures. Synchronization is archived by using frames in flight as sync:
//!   It is assumed that swapchain has limited number of images (not too many) and at worst case CPU can issue only that many frames before it will have no new frames where render to. That is good blocking/sync point.
//!   By using that knowledge we delay any host->gpu resource operations by max_frames_in_flight to be sure there won't be any data races. (for example textureDeletion is delayed to make sure gpu doesn't use it any more)
//!   But as swapchain management is left for application to do, application must make sure this is enforced and pass in this information as `max_frames_in_flight` during init.
//!   Otherwise gpu frame data can get overwritten while its still being used leading to undefined behavior.
//! * Memory: all space for vertex & index buffers is preallocated at start requiring setting appropriate limits in options. Requests to render over limit is safe but will lead to draw commands being ignored.
//!   Texture bookkeeping is also preallocated. But images themselves are allocated individually at runtime. Currently 1 image = 1 allocation which is ok for large or few images,
//!   but not great for many smaller images that can eat in max gpu allocation limit. TODO: implement hooks for general purpose allocator
//!

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("vulkan").c;
const check_vk = @import("vulkan").check_vk;

const Self = @This();
const slog = std.log.scoped(.dvui_vulkan);

const Backend = Self;
const GenericError = dvui.Backend.GenericError;
const TextureError = dvui.Backend.TextureError;
const Size = dvui.Size;

pub const Vertex = dvui.Vertex;
pub const Indice = u16;
pub const invalid_texture: *anyopaque = @ptrFromInt(0xBAD0BAD0); //@ptrFromInt(0xFFFF_FFFF);
pub const img_format = c.vk.FORMAT_R8G8B8A8_UNORM; // format for textures
pub const TextureIdx = u16;
const vs_spv align(64) = @embedFile("dvui.vert.spv").*;
const fs_spv align(64) = @embedFile("dvui.frag.spv").*;

// debug flags
const enable_breakpoints = false;
const texture_tracing = false; // trace leaks and usage

/// initialization options, caller still owns all passed in resources
pub const InitOptions = struct {
    /// vulkan loader entry point for getting Vulkan functions
    /// we are trying to keep this file independent from user code so we can't share api config (unless we make this whole file generic)
    // vkGetDeviceProcAddr: c.vk.PfnGetDeviceProcAddr,

    /// vulkan device
    dev: c.vk.Device,
    /// queue - used only for texture upload,
    /// used here only once during initialization, afterwards texture upload queue must be provided with beginFrame()
    queue: c.vk.Queue,
    /// command pool - used only for texture upload
    command_pool: c.vk.CommandPool,
    /// vulkan physical device
    pdev: c.vk.PhysicalDevice,
    /// physical device memory properties
    // mem_props: c.vk.PhysicalDeviceMemoryProperties,
    /// render pass from which renderer will be used
    render_pass: c.vk.RenderPass,
    /// optional vulkan host side allocator
    vk_alloc: ?*c.vk.AllocationCallbacks = null,

    /// How many frames can be in flight in worst case
    /// In simple single window configuration where synchronization happens when presenting should be at least (swapchain image count - 1) or larger.
    max_frames_in_flight: u32,

    /// Maximum number of indices that can be submitted in single frame
    /// Draw requests above this limit will get discarded
    max_indices_per_frame: u32 = 1024 * 128,
    max_vertices_per_frame: u32 = 1024 * 64,

    /// Maximum number of alive textures supported. global (across all overlapping frames)
    /// Note: as this is only book keeping limit it can be set quite high. Real texture memory usage could be more concerning, as well as large allocation count.
    max_textures: TextureIdx = 256,

    /// Maximum number of render textures
    /// This many render pass surpasses will be allocated for texture targets
    /// NOTE: render textures are also textures so consume max_textures budget as well when actually created
    max_texture_targets: TextureIdx = 64,

    /// error and invalid texture handle color
    /// if by any chance renderer runs out of textures or due to other reason fails to create a texture then this color will be used as texture
    error_texture_color: [4]u8 = [4]u8{ 255, 0, 255, 255 }, // default bright pink so its noticeable for debug, can be set to alpha 0 for invisible etc.

    /// if uv coords go out of bounds, how should the sampling behave
    texture_wrap: c.vk.SamplerAddressMode = c.vk.SAMPLER_ADDRESS_MODE_REPEAT,

    /// bytes - total host visible memory allocated ahead of time
    pub inline fn hostVisibleMemSize(s: @This()) u32 {
        const vtx_space = std.mem.alignForward(u32, s.max_vertices_per_frame * @sizeOf(dvui.Vertex), vk_alignment);
        const idx_space = std.mem.alignForward(u32, s.max_indices_per_frame * @sizeOf(Indice), vk_alignment);
        return s.max_frames_in_flight * (vtx_space + idx_space);
    }
};

/// TODO:
/// allocation strategy for device (gpu) memory
// const ImageAllocStrategy = union(enum) {
//     /// user provides proper allocator
//     allocator: struct {},
//     /// most basic implementation, ok for few images created with backend.createTexture
//     /// WARNING: can consume much of or hit c.vk.maxMemoryAllocationCount limit too many resources are used, see:
//     /// https://vulkan.gpuinfo.org/displaydevicelimit.php?name=maxMemoryAllocationCount&platform=all
//     allocate_each: void,
// };

const PushConstants = extern struct {
    view_scale: [2]f32,
    view_translate: [2]f32,
};

/// just simple debug and informative metrics
pub const Stats = struct {
    // per frame
    draw_calls: u16 = 0,
    verts: u32 = 0,
    indices: u32 = 0,
    // global
    textures_alive: u16 = 0,
    textures_mem: usize = 0,
};

// not owned by us:
dev: c.vk.Device,
pdev: c.vk.PhysicalDevice,
vk_alloc: ?*c.vk.AllocationCallbacks,
cmdbuf: c.vk.CommandBuffer = null,
dpool: c.vk.DescriptorPool,
queue: c.vk.Queue = null,
queue_lock: ?LockCallbacks = null,
cpool: c.vk.CommandPool = null,
cpool_lock: ?LockCallbacks = null,

// owned by us
samplers: [2]c.vk.Sampler,
frames: []FrameData,
textures: []Texture,
destroy_textures_offset: TextureIdx = 0,
destroy_textures: []TextureIdx,
pipeline: c.vk.Pipeline,
pipeline_layout: c.vk.PipelineLayout,
dset_layout: c.vk.DescriptorSetLayout,
current_frame: *FrameData, // points somewhere in frames

/// if set render to render texture instead of default cmdbuf
render_target: ?c.vk.CommandBuffer = null,
render_target_pass: c.vk.RenderPass,
render_target_pipeline: c.vk.Pipeline,

dummy_texture: Texture = undefined, // dummy/null white texture
error_texture: Texture = undefined,

host_vis_mem_idx: u32,
host_vis_mem: c.vk.DeviceMemory,
host_vis_coherent: bool,
host_vis_data: []u8, // mapped host_vis_mem
device_local_mem_idx: u32,

framebuffer_size: c.vk.Extent2D = .{ .width = 0, .height = 0 },
vtx_overflow_logged: bool = false,
idx_overflow_logged: bool = false,

// just for info / dbg
stats: Stats = .{},

/// for potentially multi threaded shared resources, lock callbacks can be set that will be called
const LockCallbacks = struct {
    lockCB: *const fn (userdata: ?*anyopaque) void = undefined,
    unlockCB: *const fn (userdata: ?*anyopaque) void = undefined,
    lock_userdata: ?*anyopaque = null, // user defined data that will be returned in callbacks
};

const FrameData = struct {
    // buffers to host_vis memory
    vtx_buff: c.vk.Buffer = null,
    vtx_data: []u8 = &.{},
    vtx_offset: u32 = 0,
    idx_buff: c.vk.Buffer = null,
    idx_data: []u8 = &.{},
    idx_offset: u32 = 0,
    /// textures to be destroyed after frames cycle through
    /// offset & len points to backend.destroy_textures[]
    destroy_textures_offset: u16 = 0,
    destroy_textures_len: u16 = 0,

    fn deinit(f: *@This(), b: *Backend) void {
        f.freeTextures(b);
        c.vk.DestroyBuffer(b.dev, f.vtx_buff, b.vk_alloc);
        c.vk.DestroyBuffer(b.dev, f.idx_buff, b.vk_alloc);
    }

    fn reset(f: *@This(), b: *Backend) void {
        f.vtx_offset = 0;
        f.idx_offset = 0;
        f.destroy_textures_offset = b.destroy_textures_offset;
        f.destroy_textures_len = 0;
    }

    fn freeTextures(f: *@This(), b: *Backend) void {
        // free textures
        for (f.destroy_textures_offset..(f.destroy_textures_offset + f.destroy_textures_len)) |i| {
            const tidx = b.destroy_textures[i % b.destroy_textures.len]; // wrap around on overflow

            var mreq: c.vk.MemoryRequirements = undefined;
            c.vk.GetImageMemoryRequirements(b.dev, b.textures[tidx].img, &mreq);

            // just for debug and monitoring
            b.stats.textures_alive -= 1;
            b.stats.textures_mem -= mreq.size;

            b.textures[tidx].deinit(b);
            b.textures[tidx].img = null;
            b.textures[tidx].dset = null;
            b.textures[tidx].img_view = null;
            b.textures[tidx].mem = null;
            b.textures[tidx].trace.addAddr(@returnAddress(), "destroy"); // keep tracing

            b.destroy_textures[i % b.destroy_textures.len] = 0xFFFF;
        }
        f.destroy_textures_len = 0;
    }
};

pub fn init(alloc: std.mem.Allocator, opt: InitOptions) !Self {
    var mem_props = std.mem.zeroInit(c.vk.PhysicalDeviceMemoryProperties, .{});
    c.vk.GetPhysicalDeviceMemoryProperties(opt.pdev, &mem_props);

    // Memory
    // host visible
    var host_coherent: bool = false;
    const host_vis_mem_type_index: u32 = blk: {
        // device local, host visible
        for (mem_props.memoryTypes[0..mem_props.memoryTypeCount], 0..) |mem_type, i|
            if ((mem_type.propertyFlags & c.vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0 and
                (mem_type.propertyFlags & c.vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0)
            {
                host_coherent = (mem_type.propertyFlags & c.vk.MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
                slog.debug("chosen host_visible_mem: {} {}", .{ i, mem_type });
                break :blk @truncate(i);
            };
        // not device local
        for (mem_props.memoryTypes[0..mem_props.memoryTypeCount], 0..) |mem_type, i|
            if ((mem_type.propertyFlags & c.vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
                host_coherent = (mem_type.propertyFlags & c.vk.MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
                slog.info("chosen host_visible_mem is NOT device local - Are we running on integrated graphics?", .{});
                slog.debug("chosen host_visible_mem: {} {}", .{ i, mem_type });
                break :blk @truncate(i);
            };
        return error.NoSuitableMemoryType;
    };
    slog.debug("host_vis allocation size: {}", .{opt.hostVisibleMemSize()});

    const memory_ai = std.mem.zeroInit(c.vk.MemoryAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = opt.hostVisibleMemSize(),
        .memoryTypeIndex = host_vis_mem_type_index,
    });
    var host_visible_mem: c.vk.DeviceMemory = undefined;
    try check_vk(c.vk.AllocateMemory(opt.dev, &memory_ai, opt.vk_alloc, &host_visible_mem));
    errdefer c.vk.FreeMemory(opt.dev, host_visible_mem, opt.vk_alloc);

    var data: ?*anyopaque = undefined;
    try check_vk(c.vk.MapMemory(opt.dev, host_visible_mem, 0, c.vk.WHOLE_SIZE, 0, &data));
    const host_vis_data = @as([*]u8, @ptrCast(@alignCast(data)))[0..opt.hostVisibleMemSize()];

    // device local mem
    const device_local_mem_idx: u32 = blk: {
        for (mem_props.memoryTypes[0..mem_props.memoryTypeCount], 0..) |mem_type, i|
            if ((mem_type.propertyFlags & c.vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0 and
                (mem_type.propertyFlags & c.vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT) == 0)
            {
                slog.debug("chosen device local mem: {} {}", .{ i, mem_type });
                break :blk @truncate(i);
            };
        break :blk host_vis_mem_type_index;
    };

    // Memory sub-allocation into FrameData
    const frames = try alloc.alloc(FrameData, opt.max_frames_in_flight);
    errdefer alloc.free(frames);
    {
        var mem_offset: usize = 0;
        for (frames) |*f| {
            f.* = .{};
            // TODO: on error here cleanup will leak previous initialized frames
            { // vertex buf
                const buffer_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
                    .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                    .size = @sizeOf(Vertex) * opt.max_vertices_per_frame,
                    .usage = c.vk.BUFFER_USAGE_VERTEX_BUFFER_BIT,
                    .sharingMode = c.vk.SHARING_MODE_EXCLUSIVE,
                });
                var buf: c.vk.Buffer = undefined;
                try check_vk(c.vk.CreateBuffer(opt.dev, &buffer_ci, opt.vk_alloc, &buf));
                errdefer c.vk.DestroyBuffer(opt.dev, buf, opt.vk_alloc);

                var mreq: c.vk.MemoryRequirements = undefined;
                c.vk.GetBufferMemoryRequirements(opt.dev, buf, &mreq);
                mem_offset = std.mem.alignForward(usize, mem_offset, mreq.alignment);

                try check_vk(c.vk.BindBufferMemory(opt.dev, buf, host_visible_mem, mem_offset));
                f.vtx_data = host_vis_data[mem_offset..][0..mreq.size];
                f.vtx_buff = buf;
                mem_offset += mreq.size;
            }
            { // index buf
                const buffer_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
                    .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                    .size = @sizeOf(Indice) * opt.max_indices_per_frame,
                    .usage = c.vk.BUFFER_USAGE_INDEX_BUFFER_BIT,
                    .sharingMode = c.vk.SHARING_MODE_EXCLUSIVE,
                });
                var buf: c.vk.Buffer = undefined;
                try check_vk(c.vk.CreateBuffer(opt.dev, &buffer_ci, opt.vk_alloc, &buf));
                errdefer c.vk.DestroyBuffer(opt.dev, buf, opt.vk_alloc);

                var mreq: c.vk.MemoryRequirements = undefined;
                c.vk.GetBufferMemoryRequirements(opt.dev, buf, &mreq);
                mem_offset = std.mem.alignForward(usize, mem_offset, mreq.alignment);

                try check_vk(c.vk.BindBufferMemory(opt.dev, buf, host_visible_mem, mem_offset));
                f.idx_data = host_vis_data[mem_offset..][0..mreq.size];
                f.idx_buff = buf;
                mem_offset += mreq.size;
            }
        }
    }

    // Descriptors
    const extra: u32 = 8; // idk, exact pool sizes returns OutOfPoolMemory slightly too soon, add extra margin
    const dpool_sizes = [_]c.vk.DescriptorPoolSize{
        //.{ .type = .uniform_buffer, .descriptor_count = opt.max_frames_in_flight },
        .{
            .type = c.vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = opt.max_textures + extra,
        },
    };
    const pool_ci = std.mem.zeroInit(c.vk.DescriptorPoolCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = opt.max_textures + extra,
        .poolSizeCount = dpool_sizes.len,
        .pPoolSizes = &dpool_sizes,
        .flags = c.vk.DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
    });
    var dpool: c.vk.DescriptorPool = undefined;
    try check_vk(c.vk.CreateDescriptorPool(opt.dev, &pool_ci, opt.vk_alloc, &dpool));

    const set_ci = std.mem.zeroInit(c.vk.DescriptorSetLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &[_]c.vk.DescriptorSetLayoutBinding{
            // c.vk.DescriptorSetLayoutBinding{
            //     .binding = ubo_binding,
            //     .descriptor_count = 1,
            //     .descriptor_type = .uniform_buffer,
            //     .stage_flags = .{ .vertex_bit = true },
            // },
            std.mem.zeroInit(c.vk.DescriptorSetLayoutBinding, .{
                .binding = tex_binding,
                .descriptorCount = 1,
                .descriptorType = c.vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .stageFlags = c.vk.SHADER_STAGE_FRAGMENT_BIT,
            }),
        },
    });

    var dsl: c.vk.DescriptorSetLayout = undefined;
    try check_vk(c.vk.CreateDescriptorSetLayout(opt.dev, &set_ci, opt.vk_alloc, &dsl));

    const pipeline_layout_ci = std.mem.zeroInit(c.vk.PipelineLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &dsl,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &[_]c.vk.PushConstantRange{
            std.mem.zeroInit(c.vk.PushConstantRange, .{
                .stageFlags = c.vk.SHADER_STAGE_VERTEX_BIT,
                .offset = 0,
                .size = @sizeOf(PushConstants),
            }),
        },
    });
    var pipeline_layout: c.vk.PipelineLayout = undefined;
    try check_vk(c.vk.CreatePipelineLayout(opt.dev, &pipeline_layout_ci, opt.vk_alloc, &pipeline_layout));
    const pipeline = try createPipeline(opt.dev, pipeline_layout, opt.render_pass, opt.vk_alloc);

    const samplers_ci = [_]c.vk.SamplerCreateInfo{
        // dvui.TextureInterpolation.nearest
        std.mem.zeroInit(c.vk.SamplerCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = c.vk.FILTER_NEAREST,
            .minFilter = c.vk.FILTER_NEAREST,
            .mipmapMode = c.vk.SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = opt.texture_wrap,
            .addressModeV = opt.texture_wrap,
            .addressModeW = opt.texture_wrap,
            .mipLodBias = 0,
            .anisotropyEnable = c.vk.FALSE,
            .maxAnisotropy = 0,
            .compareEnable = c.vk.FALSE,
            .compareOp = c.vk.COMPARE_OP_ALWAYS,
            .minLod = 0,
            .maxLod = c.vk.LOD_CLAMP_NONE,
            .borderColor = c.vk.BORDER_COLOR_INT_OPAQUE_WHITE,
            .unnormalizedCoordinates = c.vk.FALSE,
        }),
        // dvui.TextureInterpolation.linear
        std.mem.zeroInit(c.vk.SamplerCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = c.vk.FILTER_LINEAR,
            .minFilter = c.vk.FILTER_LINEAR,
            .mipmapMode = c.vk.SAMPLER_MIPMAP_MODE_LINEAR,
            .addressModeU = opt.texture_wrap,
            .addressModeV = opt.texture_wrap,
            .addressModeW = opt.texture_wrap,
            .mipLodBias = 0,
            .anisotropyEnable = c.vk.FALSE,
            .maxAnisotropy = 0,
            .compareEnable = c.vk.FALSE,
            .compareOp = c.vk.COMPARE_OP_ALWAYS,
            .minLod = 0,
            .maxLod = c.vk.LOD_CLAMP_NONE,
            .borderColor = c.vk.BORDER_COLOR_INT_OPAQUE_WHITE,
            .unnormalizedCoordinates = c.vk.FALSE,
        }),
    };
    var samplers: [2]c.vk.Sampler = undefined;
    try check_vk(c.vk.CreateSampler(opt.dev, &samplers_ci[0], opt.vk_alloc, &samplers[0]));
    try check_vk(c.vk.CreateSampler(opt.dev, &samplers_ci[1], opt.vk_alloc, &samplers[1]));

    const render_target_pass = try createOffscreenRenderPass(opt.dev, img_format);

    var res: Self = .{
        .dev = opt.dev,
        .dpool = dpool,
        .pdev = opt.pdev,
        .vk_alloc = opt.vk_alloc,

        .dset_layout = dsl,
        .samplers = samplers,
        .textures = try alloc.alloc(Texture, opt.max_textures),
        .destroy_textures = try alloc.alloc(u16, opt.max_textures),
        .render_target_pass = render_target_pass,
        .render_target_pipeline = try createPipeline(opt.dev, pipeline_layout, render_target_pass, opt.vk_alloc),
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .host_vis_mem_idx = host_vis_mem_type_index,
        .host_vis_mem = host_visible_mem,
        .host_vis_data = host_vis_data,
        .host_vis_coherent = host_coherent,
        .device_local_mem_idx = device_local_mem_idx,
        .queue = opt.queue,
        .cpool = opt.command_pool,
        .frames = frames,
        .current_frame = &frames[0],
    };
    @memset(res.textures, Texture{});
    @memset(res.destroy_textures, 0xFFFF);
    res.dummy_texture = try res.createAndUploadTexture(&[4]u8{ 255, 255, 255, 255 }, 1, 1, .nearest);
    res.error_texture = try res.createAndUploadTexture(&opt.error_texture_color, 1, 1, .nearest);

    return res;
}

/// for sync safety, better call queueWaitIdle before destruction
pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    for (self.frames) |*f| f.deinit(self);
    alloc.free(self.frames);
    for (self.textures, 0..) |tex, i| if (!tex.isNull()) {
        slog.debug("TEXTURE LEAKED {}:\n", .{i});
        tex.trace.dump();
        tex.deinit(self);
    };
    alloc.free(self.textures);
    alloc.free(self.destroy_textures);

    self.dummy_texture.deinit(self);
    self.error_texture.deinit(self);
    for (self.samplers) |s| c.vk.DestroySampler(self.dev, s, self.vk_alloc);

    c.vk.DestroyDescriptorPool(self.dev, self.dpool, self.vk_alloc);
    c.vk.DestroyDescriptorSetLayout(self.dev, self.dset_layout, self.vk_alloc);
    c.vk.DestroyPipelineLayout(self.dev, self.pipeline_layout, self.vk_alloc);
    c.vk.DestroyPipeline(self.dev, self.pipeline, self.vk_alloc);
    c.vk.DestroyPipeline(self.dev, self.render_target_pipeline, self.vk_alloc);
    c.vk.DestroyRenderPass(self.dev, self.render_target_pass, self.vk_alloc);
    c.vk.UnmapMemory(self.dev, self.host_vis_mem);
    c.vk.FreeMemory(self.dev, self.host_vis_mem, self.vk_alloc);
}

/// Begins new frame
/// Command buffer has to be in a render pass
pub fn beginFrame(self: *Self, cmdbuf: c.vk.CommandBuffer, framebuffer_size: c.vk.Extent2D) void {
    self.cmdbuf = cmdbuf;
    self.framebuffer_size = framebuffer_size;

    // advance frame pointer,
    const current_frame_idx = (@intFromPtr(self.current_frame) - @intFromPtr(self.frames.ptr) +
        @sizeOf(FrameData)) / @sizeOf(FrameData) % self.frames.len;
    const cf = &self.frames[current_frame_idx];
    self.current_frame = cf;

    // clean up old frame data
    cf.freeTextures(self);

    // reset frame data
    self.current_frame.reset(self);
    self.stats.draw_calls = 0;
    self.stats.indices = 0;
    self.stats.verts = 0;
    self.vtx_overflow_logged = false;
    self.idx_overflow_logged = false;
}

/// Ends current frame
/// returns command buffer (same one given at init)
pub fn endFrame(self: *Self) c.vk.CommandBuffer {
    const cmdbuf = self.cmdbuf;
    c.vk.CmdEndRenderPass(cmdbuf);
    self.cmdbuf = null;
    return cmdbuf;
}

// pub fn nanoTime(self: *Backend) i128 {
//     return self.base_backend.nanoTime();
// }

// pub fn sleep(self: *Backend, ns: u64) void {
//     return self.base_backend.sleep(ns);
// }

fn pushConstants(self: *Self, w: f32, h: f32, cmdbuf: c.vk.CommandBuffer) void {
    const push_constants = PushConstants{
        .view_scale = .{ 2.0 / w, 2.0 / h },
        .view_translate = .{ -1, -1 },
    };
    c.vk.CmdPushConstants(
        cmdbuf,
        self.pipeline_layout,
        c.vk.SHADER_STAGE_VERTEX_BIT,
        0,
        @sizeOf(PushConstants),
        &push_constants,
    );
}

pub fn begin(self: *Self, framebuffer_size: dvui.Size.Physical) void {
    self.render_target = null;
    if (self.cmdbuf == null) {
        @panic("dvui_vulkan_renderer: Command bufer not set before rendering started!");
    }

    const cmdbuf = self.cmdbuf;
    c.vk.CmdBindPipeline(cmdbuf, c.vk.PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);

    const viewport = c.vk.Viewport{
        .x = 0,
        .y = 0,
        .width = framebuffer_size.w,
        .height = framebuffer_size.h,
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vk.CmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));

    self.pushConstants(framebuffer_size.w, framebuffer_size.h, cmdbuf);
}

pub fn end(_: *Backend) void {}

pub fn pixelSize(self: *Backend) Size {
    // return self.base_backend.pixelSize();
    return .{ .w = @floatFromInt(self.framebuffer_size.width), .h = @floatFromInt(self.framebuffer_size.height) };
}

// pub fn windowSize(self: *Backend) dvui.Size.Natural {
//     return self.base_backend.windowSize();
// }

// pub fn contentScale(self: *Backend) f32 {
//     return self.base_backend.contentScale();
// }

pub fn drawClippedTriangles(
    self: *Backend,
    texture_: ?dvui.Texture,
    vtx: []const Vertex,
    idx: []const Indice,
    clipr: ?dvui.Rect.Physical,
) void {
    // slog.debug("draw_calls={} verts={} indices={}", .{self.stats.draw_calls, self.stats.verts, self.stats.indices});

    const texture: ?*anyopaque = if (texture_) |t| @as(*anyopaque, @ptrCast(@alignCast(t.ptr))) else null;
    const dev = self.dev;
    const cmdbuf = if (self.render_target) |t| t else self.cmdbuf;
    const cf = self.current_frame;
    const vtx_bytes = vtx.len * @sizeOf(Vertex);
    const idx_bytes = idx.len * @sizeOf(Indice);

    { // updates stats even if draw is skipped due to overflow
        self.stats.draw_calls += 1;
        self.stats.verts += @intCast(vtx.len);
        self.stats.indices += @intCast(idx.len);
    }

    if (cf.vtx_data[cf.vtx_offset..].len < vtx_bytes) {
        if (!self.vtx_overflow_logged) slog.warn("vertex buffer out of space", .{});
        self.vtx_overflow_logged = true;
        if (enable_breakpoints) @breakpoint();
        return;
    }
    if (cf.idx_data[cf.idx_offset..].len < idx_bytes) {
        // if only index buffer alone is out of bounds, we could just shrinking it... but meh
        if (!self.idx_overflow_logged) slog.warn("index buffer out of space", .{});
        self.idx_overflow_logged = true;
        if (enable_breakpoints) @breakpoint();
        return;
    }

    { // clip / scissor
        const scissor = if (clipr) |clip| c.vk.Rect2D{
            .offset = .{ .x = @intFromFloat(@max(0, clip.x)), .y = @intFromFloat(@max(0, clip.y)) },
            .extent = .{ .width = @intFromFloat(clip.w), .height = @intFromFloat(clip.h) },
        } else c.vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.framebuffer_size,
        };
        // slog.debug("scissor: {any} (clipr: {})", .{scissor, clipr == null});
        c.vk.CmdSetScissor(cmdbuf, 0, 1, @ptrCast(&scissor));
    }

    const idx_offset: u32 = cf.idx_offset;
    const vtx_offset: u32 = cf.vtx_offset;
    { // upload indices & vertices
        var modified_ranges: [2]c.vk.MappedMemoryRange = undefined;
        { // indices
            const dst = cf.idx_data[cf.idx_offset..][0..idx_bytes];
            cf.idx_offset += @intCast(dst.len);
            modified_ranges[0] = std.mem.zeroInit(c.vk.MappedMemoryRange, .{
                .sType = c.vk.STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .memory = self.host_vis_mem,
                .offset = @intFromPtr(dst.ptr) - @intFromPtr(self.host_vis_data.ptr),
                .size = dst.len,
            });
            @memcpy(dst, std.mem.sliceAsBytes(idx));
        }
        { // vertices
            const dst = cf.vtx_data[cf.vtx_offset..][0..vtx_bytes];
            cf.vtx_offset += @intCast(dst.len);
            modified_ranges[1] = std.mem.zeroInit(c.vk.MappedMemoryRange, .{
                .sType = c.vk.STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .memory = self.host_vis_mem,
                .offset = @intFromPtr(dst.ptr) - @intFromPtr(self.host_vis_data.ptr),
                .size = dst.len,
            });
            @memcpy(dst, std.mem.sliceAsBytes(vtx));
        }
        if (!self.host_vis_coherent) {
            check_vk(c.vk.FlushMappedMemoryRanges(dev, modified_ranges.len, &modified_ranges)) catch |err|
                slog.err("flushMappedMemoryRanges: {}", .{err});
        }
    }

    if (@sizeOf(Indice) != 2) unreachable;
    c.vk.CmdBindIndexBuffer(cmdbuf, cf.idx_buff, idx_offset, c.vk.INDEX_TYPE_UINT16);
    c.vk.CmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&cf.vtx_buff), &[_]c.vk.DeviceSize{vtx_offset});
    var dset: c.vk.DescriptorSet = if (texture == null) self.dummy_texture.dset else blk: {
        if (texture.? == invalid_texture) break :blk self.error_texture.dset;
        const tex = @as(*Texture, @ptrCast(@alignCast(texture)));
        if (tex.trace.index < tex.trace.addrs.len / 2 + 1) tex.trace.addAddr(@returnAddress(), "render"); // if trace has some free room, trace this
        break :blk tex.dset;
    };
    c.vk.CmdBindDescriptorSets(
        cmdbuf,
        c.vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline_layout,
        0,
        1,
        @ptrCast(&dset),
        0,
        null,
    );
    c.vk.CmdDrawIndexed(cmdbuf, @intCast(idx.len), 1, 0, 0, 0);
}

fn findEmptyTextureSlot(self: *Backend) ?TextureIdx {
    for (self.textures, 0..) |*out_tex, s| {
        if (out_tex.isNull()) return @intCast(s);
    }
    slog.err("textureCreate: Out of texture slots!", .{});
    return null;
}

pub fn textureCreate(
    self: *Backend,
    pixels: [*]const u8,
    width: u32,
    height: u32,
    interpolation: dvui.enums.TextureInterpolation,
) dvui.Texture {
    const slot = self.findEmptyTextureSlot() orelse return .{ .ptr = invalid_texture, .width = 1, .height = 1 };
    const out_tex: *Texture = &self.textures[slot];
    const tex = self.createAndUploadTexture(pixels, width, height, interpolation) catch |err| {
        if (enable_breakpoints) @breakpoint();
        slog.err("Can't create texture: {}", .{err});
        return .{ .ptr = invalid_texture, .width = 1, .height = 1 };
    };
    out_tex.* = tex;
    out_tex.trace.addAddr(@returnAddress(), "create");

    var mreq: c.vk.MemoryRequirements = undefined;
    c.vk.GetImageMemoryRequirements(self.dev, out_tex.img, &mreq);

    self.stats.textures_alive += 1;
    self.stats.textures_mem += mreq.size;
    //slog.debug("textureCreate {} ({x}) | {}", .{ slot, @intFromPtr(out_tex), self.stats.textures_alive });

    return .{ .ptr = @ptrCast(out_tex), .width = width, .height = height };
}

pub fn textureCreateTarget(
    self: *Backend,
    width: u32,
    height: u32,
    interpolation: dvui.enums.TextureInterpolation,
) GenericError!dvui.TextureTarget {
    const tex_slot = self.findEmptyTextureSlot() orelse return error.OutOfMemory;

    const dev = self.dev;

    const image_ci = std.mem.zeroInit(c.vk.ImageCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.vk.IMAGE_TYPE_2D,
        .format = img_format, // .b8g8r8_unorm
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.vk.SAMPLE_COUNT_1_BIT,
        .tiling = c.vk.IMAGE_TILING_OPTIMAL,
        .usage = c.vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.vk.IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = c.vk.SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.vk.IMAGE_LAYOUT_UNDEFINED,
    });
    var tex = self.createTextureWithMem(image_ci, interpolation) catch |err| {
        if (enable_breakpoints) @breakpoint();
        slog.err("textureCreateTarget failed to create framebuffer: {}", .{err});
        return GenericError.BackendError;
    };
    errdefer tex.deinit(self);

    const framebuffer_ci = std.mem.zeroInit(c.vk.FramebufferCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = self.render_target_pass,
        .attachmentCount = 1,
        .pAttachments = &tex.img_view,
        .width = width,
        .height = height,
        .layers = 1,
    });
    check_vk(c.vk.CreateFramebuffer(dev, &framebuffer_ci, self.vk_alloc, &tex.framebuffer)) catch |err| {
        if (enable_breakpoints) @breakpoint();
        slog.err("textureCreateTarget failed to create framebuffer: {}", .{err});
        return GenericError.BackendError;
    };
    errdefer c.vk.destroyFramebuffer(tex.framebuffer, self.vk_alloc);

    var mreq: c.vk.MemoryRequirements = undefined;
    c.vk.GetImageMemoryRequirements(dev, tex.img, &mreq);
    self.textures[tex_slot] = tex;
    self.stats.textures_alive += 1;
    self.stats.textures_mem += mreq.size;

    return .{ .ptr = &self.textures[tex_slot], .width = width, .height = height };
}

pub fn textureRead(_: *Backend, texture: dvui.Texture, pixels_out: [*]u8, width: u32, height: u32) TextureError!void {
    // return try self.base_backend.textureRead(texture, pixels_out, width, height);
    slog.debug("textureRead({}, {*}, {}x{}) Not implemented!", .{ texture, pixels_out, width, height });
    return TextureError.NotImplemented;
}

pub fn textureDestroy(self: *Backend, texture: dvui.Texture) void {
    if (texture.ptr == invalid_texture) return;
    const dslot = self.destroy_textures_offset;
    self.destroy_textures_offset = (dslot + 1) % @as(u16, @intCast(self.destroy_textures.len));
    if (self.destroy_textures[dslot] == 0xFFFF) {
        self.destroy_textures[dslot] = @intCast((@intFromPtr(texture.ptr) - @intFromPtr(self.textures.ptr)) / @sizeOf(Texture));
    }
    self.current_frame.destroy_textures_len += 1;
}

/// Read pixel data (RGBA) from `texture` into `pixels_out`.
pub fn textureReadTarget(self: *Backend, texture_target: dvui.TextureTarget, pixels_out: [*]u8) TextureError!void {
    // return self.base_backend.textureReadTarget(self, texture, pixels_out);
    _ = pixels_out;
    _ = self;
    _ = texture_target;
    return TextureError.NotImplemented;
}

/// Convert texture target made with `textureCreateTarget` into return texture
/// as if made by `textureCreate`.  After this call, texture target will not be
/// used by dvui.
pub fn textureFromTarget(self: *Backend, texture_target: dvui.TextureTarget) dvui.Texture {
    _ = self;
    return .{ .ptr = texture_target.ptr, .width = texture_target.width, .height = texture_target.height };
}

pub fn renderTarget(self: *Backend, texture_target: ?dvui.TextureTarget) GenericError!void {
    // TODO: all errors are set to unreachable, add handling?
    // slog.debug("renderTarget({?})", .{texture_target});

    if (self.render_target) |cmdbuf| { // finalize previous render target
        self.render_target = null;
        c.vk.CmdEndRenderPass(cmdbuf);
        self.endSingleTimeCommands(cmdbuf) catch unreachable;
    }

    const texture: *Texture = if (texture_target) |t| @ptrCast(@alignCast(t.ptr)) else return;
    const cmdbuf = self.beginSingleTimeCommands() catch unreachable;

    const w: f32 = @floatFromInt(self.framebuffer_size.width); // @floatFromInt(tt.fb_size.width)
    const h: f32 = @floatFromInt(self.framebuffer_size.height); // @floatFromInt(tt.fb_size.height)
    { // begin render-pass & reset viewport
        c.vk.CmdBindPipeline(cmdbuf, c.vk.PIPELINE_BIND_POINT_GRAPHICS, self.render_target_pipeline);

        const clear = c.vk.ClearValue{
            .color = .{ .float32 = .{ 0, 0, 0, 0 } },
        };
        const viewport = c.vk.Viewport{
            .x = 0,
            .y = 0,
            .width = w,
            .height = h,
            .minDepth = 0,
            .maxDepth = 1,
        };
        const render_pass_begin_info = std.mem.zeroInit(c.vk.RenderPassBeginInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.render_target_pass,
            .framebuffer = texture.framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = texture_target.?.width, .height = texture_target.?.height },
            },
            .clearValueCount = 1,
            .pClearValues = &clear,
        });
        c.vk.CmdBeginRenderPass(cmdbuf, &render_pass_begin_info, c.vk.SUBPASS_CONTENTS_INLINE);
        c.vk.CmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
    }

    self.pushConstants(w, h, cmdbuf);

    self.render_target = cmdbuf;
}

// pub fn clipboardText(self: *Backend) error{OutOfMemory}![]const u8 {
//     return self.base_backend.clipboardText();
// }

// pub fn clipboardTextSet(self: *Backend, text: []const u8) error{OutOfMemory}!void {
//     return self.base_backend.clipboardTextSet(text);
// }

// pub fn openURL(self: *Backend, url: []const u8) error{OutOfMemory}!void {
//     return self.base_backend.openURL(url);
// }

// pub fn refresh(self: *Backend) void {
//     return self.base_backend.refresh();
// }

//
// Private functions
// Some can be pub just to allow using them as utils
//

const Texture = struct {
    img: c.vk.Image = null,
    img_view: c.vk.ImageView = null,
    mem: c.vk.DeviceMemory = null,
    dset: c.vk.DescriptorSet = null,
    /// for render-textures only
    framebuffer: c.vk.Framebuffer = null,

    trace: Trace = Trace.init,
    const Trace = std.debug.ConfigurableTrace(6, 5, texture_tracing);

    pub fn isNull(self: @This()) bool {
        return self.dset == null;
    }

    pub fn deinit(tex: Texture, b: *Backend) void {
        const dev = b.dev;
        const vk_alloc = b.vk_alloc;
        check_vk(c.vk.FreeDescriptorSets(dev, b.dpool, 1, &[_]c.vk.DescriptorSet{tex.dset})) catch |err| {
            slog.err("Failed to free descriptor set: {}", .{err});
        };
        c.vk.DestroyImageView(dev, tex.img_view, vk_alloc);
        c.vk.DestroyImage(dev, tex.img, vk_alloc);
        c.vk.FreeMemory(dev, tex.mem, vk_alloc);
        c.vk.DestroyFramebuffer(dev, tex.framebuffer, vk_alloc);
    }
};

fn createPipeline(
    dev: c.vk.Device,
    layout: c.vk.PipelineLayout,
    render_pass: c.vk.RenderPass,
    vk_alloc: ?*c.vk.AllocationCallbacks,
) !c.vk.Pipeline {
    // NOTE: VK_KHR_maintenance5 (which was promoted to vulkan 1.4) deprecates ShaderModules.
    // todo: check for extension and then enable
    const ext_m5 = false; // VK_KHR_maintenance5

    const vert_shdd = std.mem.zeroInit(c.vk.ShaderModuleCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = vs_spv.len,
        .pCode = @as([*]const u32, @ptrCast(&vs_spv)),
    });
    const vert_shader_module: c.vk.ShaderModule = if (!ext_m5) m: {
        var module: c.vk.ShaderModule = undefined;
        try check_vk(c.vk.CreateShaderModule(dev, &vert_shdd, vk_alloc, &module));
        break :m module;
    } else null;

    const frag_shdd = std.mem.zeroInit(c.vk.ShaderModuleCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = fs_spv.len,
        .pCode = @as([*]const u32, @ptrCast(&fs_spv)),
    });
    const frag_shader_module: c.vk.ShaderModule = if (!ext_m5) m: {
        var module: c.vk.ShaderModule = undefined;
        try check_vk(c.vk.CreateShaderModule(dev, &frag_shdd, vk_alloc, &module));
        break :m module;
    } else null;

    var pssci = [_]c.vk.PipelineShaderStageCreateInfo{
        std.mem.zeroInit(c.vk.PipelineShaderStageCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.vk.SHADER_STAGE_VERTEX_BIT,
            .module = vert_shader_module,
            .pNext = if (ext_m5) &vert_shdd else null,
            .pName = "main",
        }),
        std.mem.zeroInit(c.vk.PipelineShaderStageCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.vk.SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_shader_module,
            .pNext = if (ext_m5) &frag_shdd else null,
            .pName = "main",
        }),
    };
    defer if (!ext_m5) for (pssci) |p| if (p.module != null) {
        c.vk.DestroyShaderModule(dev, p.module, vk_alloc);
    };

    const pvisci = std.mem.zeroInit(c.vk.PipelineVertexInputStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = VertexBindings.binding_description.len,
        .pVertexBindingDescriptions = &VertexBindings.binding_description,
        .vertexAttributeDescriptionCount = VertexBindings.attribute_description.len,
        .pVertexAttributeDescriptions = &VertexBindings.attribute_description,
    });

    const piasci = std.mem.zeroInit(c.vk.PipelineInputAssemblyStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = c.vk.FALSE,
    });

    var viewport: c.vk.Viewport = undefined;
    var scissor: c.vk.Rect2D = undefined;
    const pvsci = std.mem.zeroInit(c.vk.PipelineViewportStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = &viewport, // set in createCommandBuffers with cmdSetViewport
        .scissorCount = 1,
        .pScissors = &scissor, // set in createCommandBuffers with cmdSetScissor
    });

    const prsci = std.mem.zeroInit(c.vk.PipelineRasterizationStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = c.vk.FALSE,
        .rasterizerDiscardEnable = c.vk.FALSE,
        .polygonMode = c.vk.POLYGON_MODE_FILL,
        .cullMode = c.vk.CULL_MODE_NONE,
        .frontFace = c.vk.FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = c.vk.FALSE,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
        .lineWidth = 1,
    });

    const pmsci = std.mem.zeroInit(c.vk.PipelineMultisampleStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = c.vk.SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = c.vk.FALSE,
        .minSampleShading = 1.0,
        .alphaToCoverageEnable = c.vk.FALSE,
        .alphaToOneEnable = c.vk.FALSE,
    });

    const pdssci = std.mem.zeroInit(c.vk.PipelineDepthStencilStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = c.vk.FALSE,
        .depthWriteEnable = c.vk.FALSE,
        .depthCompareOp = c.vk.COMPARE_OP_ALWAYS,
        .depthBoundsTestEnable = c.vk.FALSE,
        .stencilTestEnable = c.vk.FALSE,
    });

    // do premultiplied alpha blending:
    // const pma_blend = c.SDL_ComposeCustomBlendMode(
    //     c.SDL_BLENDFACTOR_ONE,
    //     c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
    //     c.SDL_BLENDOPERATION_ADD,
    //     c.SDL_BLENDFACTOR_ONE,
    //     c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
    //     c.SDL_BLENDOPERATION_ADD,
    // );
    const pcbas = std.mem.zeroInit(c.vk.PipelineColorBlendAttachmentState, .{
        .blendEnable = c.vk.TRUE,
        .srcColorBlendFactor = c.vk.BLEND_FACTOR_ONE,
        .dstColorBlendFactor = c.vk.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = c.vk.BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.vk.BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.vk.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = c.vk.BLEND_OP_ADD,
        .colorWriteMask = c.vk.COLOR_COMPONENT_R_BIT |
            c.vk.COLOR_COMPONENT_G_BIT |
            c.vk.COLOR_COMPONENT_B_BIT |
            c.vk.COLOR_COMPONENT_A_BIT,
    });
    const pcbsci = std.mem.zeroInit(c.vk.PipelineColorBlendStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = c.vk.FALSE,
        .logicOp = c.vk.LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &pcbas,
        .blendConstants = [_]f32{ 0, 0, 0, 0 },
    });

    const dynstate = [_]c.vk.DynamicState{
        c.vk.DYNAMIC_STATE_VIEWPORT,
        c.vk.DYNAMIC_STATE_SCISSOR,
    };
    const pdsci = std.mem.zeroInit(c.vk.PipelineDynamicStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .flags = 0,
        .dynamicStateCount = dynstate.len,
        .pDynamicStates = &dynstate,
    });

    const gpci = std.mem.zeroInit(c.vk.GraphicsPipelineCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .flags = 0,
        .stageCount = pssci.len,
        .pStages = &pssci,
        .pVertexInputState = &pvisci,
        .pInputAssemblyState = &piasci,
        .pTessellationState = null,
        .pViewportState = &pvsci,
        .pRasterizationState = &prsci,
        .pMultisampleState = &pmsci,
        .pDepthStencilState = &pdssci,
        .pColorBlendState = &pcbsci,
        .pDynamicState = &pdsci,
        .layout = layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    });

    // std.log.debug(
    //     \\dev = {any}
    //     \\gpci = {any}
    //     \\gpci.pStages = {any}
    //     \\gpci.pVertexInputState = {any}
    //     \\gpci.pInputAssemblyState = {any}
    //     \\gpci.pViewportState = {any}
    //     \\gpci.pRasterizationState = {any}
    //     \\gpci.pMultisampleState = {any}
    //     \\gpci.pColorBlendState = {any}
    //     \\gpci.pDynamicState = {any}
    // , .{
    //     dev,                        gpci,                       gpci.pStages.*,
    //     gpci.pVertexInputState.*,   gpci.pInputAssemblyState.*, gpci.pViewportState.*,
    //     gpci.pRasterizationState.*, gpci.pMultisampleState.*,   gpci.pColorBlendState.*,
    //     gpci.pDynamicState.*,
    // });

    var pipeline: c.vk.Pipeline = undefined;
    try check_vk(c.vk.CreateGraphicsPipelines(
        dev,
        null,
        1,
        &gpci,
        vk_alloc,
        &pipeline,
    ));

    return pipeline;
}

const AllocatedBuffer = struct {
    buf: c.vk.Buffer,
    mem: c.vk.DeviceMemory,
};

/// allocates space for staging, creates buffer, and copies content to it
fn stageToBuffer(
    self: *@This(),
    buf_info: c.vk.BufferCreateInfo,
    contents: []const u8,
) !AllocatedBuffer {
    var buf: c.vk.Buffer = undefined;
    check_vk(c.vk.CreateBuffer(self.dev, &buf_info, self.vk_alloc, &buf)) catch |err| {
        slog.err("createBuffer: {}", .{err});
        return err;
    };
    errdefer c.vk.DestroyBuffer(self.dev, buf, self.vk_alloc);

    var mreq: c.vk.MemoryRequirements = undefined;
    c.vk.GetBufferMemoryRequirements(self.dev, buf, &mreq);

    const memory_ai = std.mem.zeroInit(c.vk.MemoryAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mreq.size,
        .memoryTypeIndex = self.host_vis_mem_idx,
    });
    var mem: c.vk.DeviceMemory = undefined;
    check_vk(c.vk.AllocateMemory(self.dev, &memory_ai, self.vk_alloc, &mem)) catch |err| {
        slog.err("Failed to alloc texture mem: {}", .{err});
        return err;
    };
    errdefer c.vk.FreeMemory(self.dev, mem, self.vk_alloc);

    const mem_offset = 0;
    try check_vk(c.vk.BindBufferMemory(self.dev, buf, mem, mem_offset));

    var mem_data: ?*anyopaque = undefined;
    try check_vk(c.vk.MapMemory(self.dev, mem, 0, c.vk.WHOLE_SIZE, 0, &mem_data));
    const data = @as([*]u8, @ptrCast(@alignCast(mem_data)))[0..mreq.size];
    @memcpy(data[0..contents.len], contents);
    if (!self.host_vis_coherent) {
        const mem_ranges = [_]c.vk.MappedMemoryRange{std.mem.zeroInit(c.vk.MappedMemoryRange, .{
            .sType = c.vk.STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = mem,
            .offset = mem_offset,
            .size = mreq.size,
        })};
        try check_vk(c.vk.FlushMappedMemoryRanges(self.dev, mem_ranges.len, &mem_ranges));
    }

    return .{ .buf = buf, .mem = mem };
}

pub fn beginSingleTimeCommands(self: *Self) !c.vk.CommandBuffer {
    if (self.cpool_lock) |l| l.lockCB(l.lock_userdata);
    defer if (self.cpool_lock) |l| l.unlockCB(l.lock_userdata);

    const command_buffer_ai = std.mem.zeroInit(c.vk.CommandBufferAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.cpool,
        .level = c.vk.COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    });
    var cmdbuf: c.vk.CommandBuffer = undefined;
    check_vk(c.vk.AllocateCommandBuffers(self.dev, &command_buffer_ai, &cmdbuf)) catch |err| {
        if (enable_breakpoints) @breakpoint();
        return err;
    };

    const cmd_begin_info = std.mem.zeroInit(c.vk.CommandBufferBeginInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    try check_vk(c.vk.BeginCommandBuffer(cmdbuf, &cmd_begin_info));

    return cmdbuf;
}

pub fn endSingleTimeCommands(self: *Self, cmdbuf: c.vk.CommandBuffer) !void {
    try check_vk(c.vk.EndCommandBuffer(cmdbuf));
    defer c.vk.FreeCommandBuffers(self.dev, self.cpool, 1, @ptrCast(&cmdbuf));

    if (self.queue_lock) |l| l.lockCB(l.lock_userdata);
    defer if (self.queue_lock) |l| l.unlockCB(l.lock_userdata);
    const qs = [_]c.vk.SubmitInfo{std.mem.zeroInit(c.vk.SubmitInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmdbuf,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    })};
    try check_vk(c.vk.QueueSubmit(self.queue, qs.len, &qs, null));

    // TODO: is there better way to sync this than stalling the queue? barriers or something
    check_vk(c.vk.QueueWaitIdle(self.queue)) catch |err| {
        slog.warn("queueWaitIdle failed: {}", .{err});
    };
}

pub fn createTextureWithMem(
    self: Backend,
    img_info: c.vk.ImageCreateInfo,
    interpolation: dvui.enums.TextureInterpolation,
) !Texture {
    const dev = self.dev;

    var img: c.vk.Image = undefined;
    try check_vk(c.vk.CreateImage(dev, &img_info, self.vk_alloc, &img));
    errdefer c.vk.DestroyImage(dev, img, self.vk_alloc);

    var mreq: c.vk.MemoryRequirements = undefined;
    c.vk.GetImageMemoryRequirements(dev, img, &mreq);

    const memory_ai = std.mem.zeroInit(c.vk.MemoryAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mreq.size,
        .memoryTypeIndex = self.device_local_mem_idx,
    });
    var mem: c.vk.DeviceMemory = undefined;
    check_vk(c.vk.AllocateMemory(dev, &memory_ai, self.vk_alloc, &mem)) catch |err| {
        slog.err("Failed to alloc texture mem: {}", .{err});
        return err;
    };
    errdefer c.vk.FreeMemory(dev, mem, self.vk_alloc);
    try check_vk(c.vk.BindImageMemory(dev, img, mem, 0));

    const srr = std.mem.zeroInit(c.vk.ImageSubresourceRange, .{
        .aspectMask = c.vk.IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    });
    const image_view_ci = std.mem.zeroInit(c.vk.ImageViewCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .flags = 0,
        .image = img,
        .viewType = c.vk.IMAGE_VIEW_TYPE_2D,
        .format = img_format,
        .components = .{
            .r = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .g = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .b = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .a = c.vk.COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = srr,
    });
    var img_view: c.vk.ImageView = undefined;
    try check_vk(c.vk.CreateImageView(dev, &image_view_ci, self.vk_alloc, &img_view));
    errdefer c.vk.DestroyImageView(dev, img_view, self.vk_alloc);

    const dset_ai = std.mem.zeroInit(c.vk.DescriptorSetAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.dpool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.dset_layout,
    });
    var dset: [1]c.vk.DescriptorSet = undefined;
    check_vk(c.vk.AllocateDescriptorSets(dev, &dset_ai, &dset)) catch |err| {
        if (enable_breakpoints) @breakpoint();
        slog.err("Failed to allocate descriptor set: {}", .{err});
        return err;
    };

    const dii: [1]c.vk.DescriptorImageInfo = .{std.mem.zeroInit(c.vk.DescriptorImageInfo, .{
        .sampler = self.samplers[@intFromEnum(interpolation)],
        .imageView = img_view,
        .imageLayout = c.vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    })};
    const write_dss: [1]c.vk.WriteDescriptorSet = .{std.mem.zeroInit(c.vk.WriteDescriptorSet, .{
        .sType = c.vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = dset[0],
        .dstBinding = tex_binding,
        .descriptorCount = 1,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &dii,
    })};
    c.vk.UpdateDescriptorSets(dev, write_dss.len, &write_dss, 0, null);

    return Texture{ .img = img, .img_view = img_view, .mem = mem, .dset = dset[0] };
}

pub fn createAndUploadTexture(
    self: *Backend,
    pixels: [*]const u8,
    width: u32,
    height: u32,
    interpolation: dvui.enums.TextureInterpolation,
) !Texture {
    // slog.info("img {}x{}; req size {}", .{ width, height, mreq.size });
    const image_ci = std.mem.zeroInit(c.vk.ImageCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.vk.IMAGE_TYPE_2D,
        .format = img_format, // .b8g8r8_unorm
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.vk.SAMPLE_COUNT_1_BIT,
        .tiling = c.vk.IMAGE_TILING_OPTIMAL,
        .usage = c.vk.IMAGE_USAGE_TRANSFER_DST_BIT | c.vk.IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = c.vk.SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.vk.IMAGE_LAYOUT_UNDEFINED,
    });
    const tex = try self.createTextureWithMem(image_ci, interpolation);
    errdefer tex.deinit(self);

    const dev = self.dev;
    var cmdbuf = try self.beginSingleTimeCommands();
    // TODO: review what error handling should be optimal - if anything fails we should discard cmdbuf not submit it
    defer self.endSingleTimeCommands(cmdbuf) catch unreachable;

    var mreq: c.vk.MemoryRequirements = undefined;
    c.vk.GetImageMemoryRequirements(dev, tex.img, &mreq);

    const buffer_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .flags = 0,
        .size = mreq.size,
        .usage = c.vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = c.vk.SHARING_MODE_EXCLUSIVE,
    });
    const img_staging = try self.stageToBuffer(buffer_ci, pixels[0 .. width * height * 4]);
    defer c.vk.DestroyBuffer(dev, img_staging.buf, self.vk_alloc);
    defer c.vk.FreeMemory(dev, img_staging.mem, self.vk_alloc);

    const srr = std.mem.zeroInit(c.vk.ImageSubresourceRange, .{
        .aspectMask = c.vk.IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    });
    { // transition image to dst_optimal
        const img_barrier = std.mem.zeroInit(c.vk.ImageMemoryBarrier, .{
            .sType = c.vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = 0,
            .dstAccessMask = c.vk.ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = c.vk.IMAGE_LAYOUT_UNDEFINED,
            .newLayout = c.vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = c.vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.vk.QUEUE_FAMILY_IGNORED,
            .image = tex.img,
            .subresourceRange = srr,
        });
        c.vk.CmdPipelineBarrier(
            cmdbuf,
            c.vk.PIPELINE_STAGE_HOST_BIT | c.vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.vk.PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &img_barrier,
        );

        try self.endSingleTimeCommands(cmdbuf);
        cmdbuf = try self.beginSingleTimeCommands();
    }
    { // copy staging -> img
        const buff_img_copy = std.mem.zeroInit(c.vk.BufferImageCopy, .{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = c.vk.IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        });
        c.vk.CmdCopyBufferToImage(cmdbuf, img_staging.buf, tex.img, c.vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &buff_img_copy);

        try self.endSingleTimeCommands(cmdbuf);
        cmdbuf = try self.beginSingleTimeCommands();
    }
    { // transition to read only optimal
        const img_barrier = std.mem.zeroInit(c.vk.ImageMemoryBarrier, .{
            .sType = c.vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = c.vk.ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = c.vk.ACCESS_SHADER_READ_BIT,
            .oldLayout = c.vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = c.vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = c.vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.vk.QUEUE_FAMILY_IGNORED,
            .image = tex.img,
            .subresourceRange = srr,
        });
        c.vk.CmdPipelineBarrier(
            cmdbuf,
            c.vk.PIPELINE_STAGE_TRANSFER_BIT,
            c.vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &img_barrier,
        );

        try self.endSingleTimeCommands(cmdbuf);
        cmdbuf = try self.beginSingleTimeCommands();
    }

    return tex;
}

pub fn createOffscreenRenderPass(dev: c.vk.Device, format: c.vk.Format) !c.vk.RenderPass {
    var subpasses: [1]c.vk.SubpassDescription = undefined;
    var color_attachments: [1]c.vk.AttachmentDescription = undefined;

    { // Render to framebuffer
        color_attachments[0] = std.mem.zeroInit(c.vk.AttachmentDescription, .{
            .format = format, // swapchain / framebuffer image format
            .samples = c.vk.SAMPLE_COUNT_1_BIT,
            .loadOp = c.vk.ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.vk.ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.vk.ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.vk.ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.vk.IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        });
        const color_attachment_ref = std.mem.zeroInit(c.vk.AttachmentReference, .{
            .attachment = 0,
            .layout = c.vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });
        subpasses[0] = std.mem.zeroInit(c.vk.SubpassDescription, .{
            .pipelineBindPoint = c.vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
        });
    }

    // { // texture render targets
    //     for (1..subpasses.len) |i| {
    //         color_attachments[i] = c.vk.AttachmentDescription{
    //             .format = img_format,
    //             .samples = .{ .@"1_bit" = true },
    //             .load_op = .clear, // TODO: .dont_care?
    //             .store_op = .store,
    //             .stencil_load_op = .dont_care,
    //             .stencil_store_op = .dont_care,
    //             .initial_layout = .undefined,
    //             .final_layout = .color_attachment_optimal, // .read_only_optimal, // TODO: review
    //         };
    //         const rt_color_attachment_ref = [_]c.vk.AttachmentReference{.{
    //             .attachment = @intCast(i),
    //             .layout = .color_attachment_optimal,
    //         }};
    //         subpasses[i] = c.vk.SubpassDescription{
    //             .pipeline_bind_point = .graphics,
    //             .color_attachment_count = rt_color_attachment_ref.len,
    //             .p_color_attachments = &rt_color_attachment_ref,
    //         };
    //     }
    // }

    const render_pass_ci = std.mem.zeroInit(c.vk.RenderPassCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = color_attachments.len,
        .pAttachments = &color_attachments,
        .subpassCount = subpasses.len,
        .pSubpasses = &subpasses,
        .dependencyCount = 0,
        .pDependencies = null, // @ptrCast(&dep)
    });
    var render_pass: c.vk.RenderPass = undefined;
    try check_vk(c.vk.CreateRenderPass(dev, &render_pass_ci, null, &render_pass));

    return render_pass;
}

const VertexBindings = struct {
    const binding_description = [_]c.vk.VertexInputBindingDescription{.{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .inputRate = c.vk.VERTEX_INPUT_RATE_VERTEX,
    }};

    const attribute_description = [_]c.vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = c.vk.FORMAT_R32G32_SFLOAT,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = c.vk.FORMAT_R8G8B8A8_UNORM,
            .offset = @offsetOf(Vertex, "col"),
        },
        .{
            .binding = 0,
            .location = 2,
            .format = c.vk.FORMAT_R32G32_SFLOAT,
            .offset = @offsetOf(Vertex, "uv"),
        },
    };
};

pub const tex_binding = 1; // shader binding slot must match shader
// pub const ubo_binding = 0; // uniform binding slot must match shader
// const Uniform = extern struct {
//     viewport_size: @Vector(2, f32),
// };

/// device memory min alignment
/// we could query it at runtime, but this is reasonable safe number. We don't use this for anything critical.
/// https://vulkan.gpuinfo.org/displaydevicelimit.php?name=minMemoryMapAlignment&platform=all
const vk_alignment = if (builtin.target.os.tag.isDarwin()) 16384 else 4096;
