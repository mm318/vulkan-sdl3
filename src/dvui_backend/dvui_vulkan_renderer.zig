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
const slog = std.log.scoped(.dvui_vulkan);
const dvui = @import("dvui");
const c = @import("vulkan").c;
const check_vk = @import("vulkan").check_vk;
const Size = dvui.Size;

const vs_spv align(64) = @embedFile("dvui.vert.spv").*;
const fs_spv align(64) = @embedFile("dvui.frag.spv").*;

const Self = @This();

//
// Backend interface function overrides
//  see: dvui/Backend.zig
//
const Backend = Self;

pub const Vertex = dvui.Vertex;
pub const Indice = u16;
pub const invalid_texture: *anyopaque = @ptrFromInt(0xBAD0BAD0); //@ptrFromInt(0xFFFF_FFFF);
pub const img_format = c.vk.FORMAT_R8G8B8A8_UNORM; // format for textures
pub const TextureIdx = u16;

// debug flags
const enable_breakpoints = false;
const texture_tracing = false; // tace leaks and usage

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

// we need stable pointer to this, but its not worth allocating it, so make it global
var g_dev_wrapper: c.vk.DeviceWrapper = undefined;

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
render_pass_texture_target: c.vk.RenderPass,
samplers: [2]c.vk.Sampler,
frames: []FrameData,
textures: []Texture,
texture_targets: []TextureTarget,
destroy_textures_offset: TextureIdx = 0,
destroy_textures: []TextureIdx,
pipeline: c.vk.Pipeline,
pipeline_layout: c.vk.PipelineLayout,
dset_layout: c.vk.DescriptorSetLayout,
render_target: ?c.vk.CommandBuffer = null,
current_frame: *FrameData, // points somewhere in frames

win_extent: c.vk.Extent2D = undefined,
dummy_texture: Texture = undefined, // dummy/null white texture
error_texture: Texture = undefined,

host_vis_mem_idx: u32,
host_vis_mem: c.vk.DeviceMemory,
host_vis_coherent: bool,
host_vis_data: []u8, // mapped host_vis_mem
//host_vis_offset: usize = 0, // linearly advaces and wraps to 0 - assumes size is large enough to not overwrite old still in flight data
device_local_mem_idx: u32,

framebuffer_size: c.vk.Extent2D = .{ .width = 0, .height = 0 },
vtx_overflow_logged: bool = false,
idx_overflow_logged: bool = false,
stats: Stats = .{}, // just for info / dbg

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
        b.dev.destroyBuffer(f.vtx_buff, b.vk_alloc);
        b.dev.destroyBuffer(f.idx_buff, b.vk_alloc);
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
            // just for debug and monitoring
            b.stats.textures_alive -= 1;
            b.stats.textures_mem -= b.dev.getImageMemoryRequirements(b.textures[tidx].img).size;

            //slog.debug("destroy texture {}({x}) | {}", .{ tidx, @intFromPtr(&b.textures[tidx]), b.stats.textures_alive });
            b.textures[tidx].deinit(b);
            b.textures[tidx].img = null;
            b.textures[tidx].dset = null;
            b.textures[tidx].img_view = null;
            b.textures[tidx].mem = null;
            b.textures[tidx].trace.addAddr(@returnAddress(), "destroy"); // keep tracing
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

    const render_pass_texture_target = try createRenderPass(opt.dev, img_format);

    const pipeline_layout_ci = std.mem.zeroInit(c.vk.PipelineLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &dsl,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &[_]c.vk.PushConstantRange{
            std.mem.zeroInit(c.vk.PushConstantRange, .{
                .stageFlags = c.vk.SHADER_STAGE_VERTEX_BIT,
                .offset = 0,
                .size = @sizeOf(f32) * 4,
            }),
        },
    });
    var pipeline_layout: c.vk.PipelineLayout = undefined;
    try check_vk(c.vk.CreatePipelineLayout(opt.dev, &pipeline_layout_ci, opt.vk_alloc, &pipeline_layout));
    const pipeline = try createPipeline(opt.dev, pipeline_layout, opt.render_pass, opt.vk_alloc);

    const samplers_ci = [_]c.vk.SamplerCreateInfo{
        .{ // dvui.TextureInterpolation.nearest
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = opt.texture_wrap,
            .address_mode_v = opt.texture_wrap,
            .address_mode_w = opt.texture_wrap,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 0,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = c.vk.LOD_CLAMP_NONE,
            .border_color = .int_opaque_white,
            .unnormalized_coordinates = .false,
        },
        .{ // dvui.TextureInterpolation.linear
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = opt.texture_wrap,
            .address_mode_v = opt.texture_wrap,
            .address_mode_w = opt.texture_wrap,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 0,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = c.vk.LOD_CLAMP_NONE,
            .border_color = .int_opaque_white,
            .unnormalized_coordinates = .false,
        },
    };
    var samplers: [2]c.vk.Sampler = undefined;
    try check_vk(c.vk.CreateSampler(opt.dev, &samplers_ci[0], opt.vk_alloc, &samplers[0]));
    try check_vk(c.vk.CreateSampler(opt.dev, &samplers_ci[1], opt.vk_alloc, &samplers[1]));

    var res: Self = .{
        .dev = opt.dev,
        .dpool = dpool,
        .pdev = opt.pdev,
        .vk_alloc = opt.vk_alloc,

        .dset_layout = dsl,
        .samplers = samplers,
        .textures = try alloc.alloc(Texture, opt.max_textures),
        .texture_targets = try alloc.alloc(TextureTarget, opt.max_texture_targets),
        .destroy_textures = try alloc.alloc(u16, opt.max_textures),
        .render_pass_texture_target = render_pass_texture_target,
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
    @memset(res.texture_targets, TextureTarget{});
    res.dummy_texture = try res.createAndUplaodTexture(&[4]u8{ 255, 255, 255, 255 }, 1, 1, .nearest);
    res.error_texture = try res.createAndUplaodTexture(&opt.error_texture_color, 1, 1, .nearest);
    return res;
}

/// for sync safety, better call queueWaitIdle before destruction
pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    for (self.texture_targets) |tt| if (!tt.isNull()) {
        self.textureDestroy(.{ .ptr = &self.textures[tt.tex_idx], .width = 0, .height = 0 });
        self.dev.destroyFramebuffer(tt.framebuffer, self.vk_alloc);
    };
    alloc.free(self.texture_targets);
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
    for (self.samplers) |s| self.dev.destroySampler(s, self.vk_alloc);

    self.dev.destroyDescriptorPool(self.dpool, self.vk_alloc);
    self.dev.destroyDescriptorSetLayout(self.dset_layout, self.vk_alloc);
    self.dev.destroyPipelineLayout(self.pipeline_layout, self.vk_alloc);
    self.dev.destroyPipeline(self.pipeline, self.vk_alloc);
    self.dev.unmapMemory(self.host_vis_mem);
    self.dev.freeMemory(self.host_vis_mem, self.vk_alloc);
    self.dev.destroyRenderPass(self.render_pass_texture_target, self.vk_alloc);
}

pub fn backend(self: *Self) dvui.Backend {
    var b = dvui.Backend.init(@as(*dvui.backend, @ptrCast(self)), dvui.backend);
    {
        // hijack base backend by replacing vtable with our own
        // WARNING: this is not safe and asking for trouble, but done to allow only implementing rendering
        // TODO: figure out how to do this cleanly
        const implementation = Self;
        { // manual type checks
            // When updating dvui: copy paste from dvui.Backend.VTable.I here as RefVTable
            const Context = Self;
            const RefVTable = struct {
                pub const nanoTime = *const fn (ctx: Context) i128;
                pub const sleep = *const fn (ctx: Context, ns: u64) void;

                pub const begin = *const fn (ctx: Context, arena: std.mem.Allocator) void;
                pub const end = *const fn (ctx: Context) void;

                pub const pixelSize = *const fn (ctx: Context) dvui.Size.Physical;
                pub const windowSize = *const fn (ctx: Context) dvui.Size.Natural;
                pub const contentScale = *const fn (ctx: Context) f32;

                pub const drawClippedTriangles = *const fn (ctx: Context, texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const u16, clipr: ?dvui.Rect.Physical) void;

                pub const textureCreate = *const fn (ctx: Context, pixels: [*]u8, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) dvui.Texture;
                pub const textureDestroy = *const fn (ctx: Context, texture: dvui.Texture) void;
                pub const textureFromTarget = *const fn (ctx: Context, texture: dvui.TextureTarget) dvui.Texture;

                pub const textureCreateTarget = *const fn (ctx: Context, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) error{ OutOfMemory, TextureCreate }!dvui.TextureTarget;
                pub const textureReadTarget = *const fn (ctx: Context, texture: dvui.TextureTarget, pixels_out: [*]u8) error{TextureRead}!void;
                pub const renderTarget = *const fn (ctx: Context, texture: ?dvui.TextureTarget) void;

                pub const clipboardText = *const fn (ctx: Context) error{OutOfMemory}![]const u8;
                pub const clipboardTextSet = *const fn (ctx: Context, text: []const u8) error{OutOfMemory}!void;

                pub const openURL = *const fn (ctx: Context, url: []const u8) error{OutOfMemory}!void;
                pub const refresh = *const fn (ctx: Context) void;
            };
            if (@sizeOf(RefVTable) != @sizeOf(dvui.Backend.VTable.I)) @compileError("Backend not up to date with dvui!");
            const I = RefVTable; // autofix
            inline for (@typeInfo(I).@"struct".decls) |decl| {
                const hasField = @hasDecl(implementation, decl.name);
                const DeclType = @field(I, decl.name);
                if (!hasField) @compileError("Backend type " ++ @typeName(implementation) ++ " has no declaration '" ++ decl.name ++ ": " ++ @typeName(DeclType) ++ "'");
            }
        }
        const I = dvui.Backend.VTable.I;
        inline for (@typeInfo(I).@"struct".decls) |decl| {
            // DANGER: bypasses type safety here, but it should be cought above as long as its kept up to date
            @field(b.vtable, decl.name) = @ptrCast(&@field(implementation, decl.name));
        }
        return b;
    }
}

pub const RenderPassInfo = struct {
    framebuffer: c.vk.Framebuffer,
    render_area: c.vk.Rect2D,
};

/// Begins new frame
/// Command buffer has to be in a render pass
pub fn beginFrame(self: *Self, cmdbuf: c.vk.CommandBuffer, framebuffer_size: c.vk.Extent2D) void {
    self.cmdbuf = cmdbuf;
    self.framebuffer_size = framebuffer_size;

    // advance frame pointer,
    const current_frame_idx = (@intFromPtr(self.current_frame) - @intFromPtr(self.frames.ptr) + @sizeOf(FrameData)) / @sizeOf(FrameData) % self.frames.len;
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
    self.dev.cmdEndRenderPass(cmdbuf);
    self.cmdbuf = null;
    return cmdbuf;
}

// pub fn nanoTime(self: *Backend) i128 {
//     return self.base_backend.nanoTime();
// }

// pub fn sleep(self: *Backend, ns: u64) void {
//     return self.base_backend.sleep(ns);
// }

//pub const begin = Override.begin;
pub fn begin(self: *Self) void {
    self.render_target = null;
    if (self.cmdbuf == null) @panic("dvui_vulkan_renderer: Command bufer not set before rendering started!");
    // TODO: FIXME: get rid of this or do it more cleanly
    //  WARNING: very risky as sdl_backend calls renderer, but have no other way to pass through arena
    // self.base_backend.begin(arena); // call base

    const dev = self.dev;
    const cmdbuf = self.cmdbuf;
    dev.cmdBindPipeline(cmdbuf, .graphics, self.pipeline);

    const win_size = self.windowSize();
    const extent: c.vk.Extent2D = .{ .width = @intFromFloat(win_size.w), .height = @intFromFloat(win_size.h) };
    self.win_extent = extent;
    const viewport = c.vk.Viewport{
        .x = 0,
        .y = 0,
        .width = win_size.w,
        .height = win_size.h,
        .min_depth = 0,
        .max_depth = 1,
    };
    dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));

    const PushConstants = struct {
        view_scale: @Vector(2, f32),
        view_translate: @Vector(2, f32),
    };
    const push_constants = PushConstants{
        .view_scale = .{ 2.0 / win_size.w, 2.0 / win_size.h },
        .view_translate = .{ -1.0, -1.0 },
    };
    dev.cmdPushConstants(cmdbuf, self.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), &push_constants);
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

pub fn drawClippedTriangles(self: *Backend, texture_: ?dvui.Texture, vtx: []const Vertex, idx: []const Indice, clipr: ?dvui.Rect) void {
    if (self.render_target != null) return; // TODO: render to textures
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
            .extent = self.win_extent,
        };
        dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&scissor));
    }

    const idx_offset: u32 = cf.idx_offset;
    const vtx_offset: u32 = cf.vtx_offset;
    { // upload indices & vertices
        var modified_ranges: [2]c.vk.MappedMemoryRange = undefined;
        { // indices
            const dst = cf.idx_data[cf.idx_offset..][0..idx_bytes];
            cf.idx_offset += @intCast(dst.len);
            modified_ranges[0] = .{ .memory = self.host_vis_mem, .offset = @intFromPtr(dst.ptr) - @intFromPtr(self.host_vis_data.ptr), .size = dst.len };
            @memcpy(dst, std.mem.sliceAsBytes(idx));
        }
        { // vertices
            const dst = cf.vtx_data[cf.vtx_offset..][0..vtx_bytes];
            cf.vtx_offset += @intCast(dst.len);
            modified_ranges[1] = .{ .memory = self.host_vis_mem, .offset = @intFromPtr(dst.ptr) - @intFromPtr(self.host_vis_data.ptr), .size = dst.len };
            @memcpy(dst, std.mem.sliceAsBytes(vtx));
        }
        if (!self.host_vis_coherent)
            dev.flushMappedMemoryRanges(modified_ranges.len, &modified_ranges) catch |err|
                slog.err("flushMappedMemoryRanges: {}", .{err});
    }

    if (@sizeOf(Indice) != 2) unreachable;
    dev.cmdBindIndexBuffer(cmdbuf, cf.idx_buff, idx_offset, .uint16);
    dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&cf.vtx_buff), &[_]c.vk.DeviceSize{vtx_offset});
    var dset: c.vk.DescriptorSet = if (texture == null) self.dummy_texture.dset else blk: {
        if (texture.? == invalid_texture) break :blk self.error_texture.dset;
        const tex = @as(*Texture, @ptrCast(@alignCast(texture)));
        if (tex.trace.index < tex.trace.addrs.len / 2 + 1) tex.trace.addAddr(@returnAddress(), "render"); // if trace has some free room, trace this
        break :blk tex.dset;
    };
    dev.cmdBindDescriptorSets(
        cmdbuf,
        .graphics,
        self.pipeline_layout,
        0,
        1,
        @ptrCast(&dset),
        0,
        null,
    );
    dev.cmdDrawIndexed(cmdbuf, @intCast(idx.len), 1, 0, 0, 0);
}

fn findEmptyTextureSlot(self: *Backend) ?TextureIdx {
    for (self.textures, 0..) |*out_tex, s| {
        if (out_tex.isNull()) return @intCast(s);
    }
    slog.err("textureCreate: Out of texture slots!", .{});
    return null;
}

pub fn textureCreate(self: *Backend, pixels: [*]u8, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) dvui.Texture {
    const slot = self.findEmptyTextureSlot() orelse return .{ .ptr = invalid_texture, .width = 1, .height = 1 };
    const out_tex: *Texture = &self.textures[slot];
    const tex = self.createAndUplaodTexture(pixels, width, height, interpolation) catch |err| {
        if (enable_breakpoints) @breakpoint();
        slog.err("Can't create texture: {}", .{err});
        return .{ .ptr = invalid_texture, .width = 1, .height = 1 };
    };
    out_tex.* = tex;
    out_tex.trace.addAddr(@returnAddress(), "create");

    self.stats.textures_alive += 1;
    self.stats.textures_mem += self.dev.getImageMemoryRequirements(out_tex.img).size;
    //slog.debug("textureCreate {} ({x}) | {}", .{ slot, @intFromPtr(out_tex), self.stats.textures_alive });
    return .{ .ptr = @ptrCast(out_tex), .width = width, .height = height };
}
pub fn textureCreateTarget(self: *Backend, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !dvui.Texture {
    const enable = false;
    if (!enable) return error.NotSupported else {
        const target_slot = blk: {
            for (self.texture_targets, 0..) |*tt, s| {
                if (tt.isNull()) break :blk s;
            }
            slog.err("textureCreateTarget: Out of texture target slots! Texture discarded.", .{});
            return error.OutOfTextureTargets;
        };
        const tex_slot = self.findEmptyTextureSlot() orelse return error.OutOfTextures;

        const dev = self.dev;
        const tex = self.createTextureWithMem(.{
            .image_type = .@"2d",
            .format = img_format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{
                .color_attachment_bit = true,
                .sampled_bit = true,
            },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, interpolation) catch |err| {
            slog.err("textureCreateTarget failed to create framebuffer: {}", .{err});
            return err;
        };
        errdefer tex.deinit(self);

        const fb = dev.createFramebuffer(&.{
            .flags = .{},
            .render_pass = self.render_pass_texture_target,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&tex.img_view),
            .width = width,
            .height = height,
            .layers = 1,
        }, self.vk_alloc) catch |err| {
            slog.err("textureCreateTarget failed to create framebuffer: {}", .{err});
            return err;
        };
        errdefer dev.destroyFramebuffer(fb, self.vk_alloc);

        self.textures[tex_slot] = tex;
        self.texture_targets[target_slot] = TextureTarget{
            .tex_idx = tex_slot,
            .framebuffer = fb,
            .fb_size = .{ .width = width, .height = height },
        };
        return &self.texture_targets[target_slot];
    }
}
pub fn textureRead(self: *Backend, texture: dvui.Texture, pixels_out: [*]u8, width: u32, height: u32) !void {
    // return try self.base_backend.textureRead(texture, pixels_out, width, height);
    slog.debug("textureRead({}, {*}, {}x{}) Not implemented!", .{ texture, pixels_out, width, height });
    _ = self; // autofix
    return error.NotSupported;
}
pub fn textureDestroy(self: *Backend, texture: dvui.Texture) void {
    if (texture.ptr == invalid_texture) return;
    const dslot = self.destroy_textures_offset;
    self.destroy_textures_offset = (dslot + 1) % @as(u16, @intCast(self.destroy_textures.len));
    if (self.destroy_textures[dslot] != 0xFFFF) {
        self.destroy_textures[dslot] = @intCast((@intFromPtr(texture.ptr) - @intFromPtr(self.textures.ptr)) / @sizeOf(Texture));
    }
    self.current_frame.destroy_textures_len += 1;
    // slog.debug("schedule destroy texture: {} ({x})", .{ self.destroy_textures[dslot], @intFromPtr(texture) });
}

/// Read pixel data (RGBA) from `texture` into `pixels_out`.
pub fn textureReadTarget(self: *Backend, texture: dvui.TextureTarget, pixels_out: [*]u8) !void {
    // return self.base_backend.textureReadTarget(self, texture, pixels_out);
    _ = pixels_out;
    _ = self;
    _ = texture;
    return error.NotSupported;
}

/// Convert texture target made with `textureCreateTarget` into return texture
/// as if made by `textureCreate`.  After this call, texture target will not be
/// used by dvui.
pub fn textureFromTarget(self: *Backend, texture: dvui.TextureTarget) dvui.Texture {
    // return self.base_backend.textureFromTarget(self, texture);
    _ = texture;
    return .{ .ptr = @ptrCast(&self.error_texture), .width = 0, .height = 0 };
}

pub fn renderTarget(self: *Backend, texture: dvui.Texture) void {
    // TODO: all errors are set to unreachable, add handling?
    slog.debug("renderTarget({?})", .{texture});
    const dev = self.dev;

    if (self.render_target) |cmdbuf| { // finalize previous render target
        self.render_target = null;
        dev.cmdEndRenderPass(cmdbuf);
        self.endSingleTimeCommands(cmdbuf) catch unreachable;
    }

    const tt: *TextureTarget = @ptrCast(@alignCast(texture.ptr));
    const cmdbuf = self.beginSingleTimeCommands() catch unreachable;
    self.render_target = cmdbuf;

    { // begin render-pass & reset viewport
        const clear = c.vk.ClearValue{
            .color = .{ .float_32 = .{ 0, 0, 0, 0 } },
        };
        const viewport = c.vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(tt.fb_size.width),
            .height = @floatFromInt(tt.fb_size.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        dev.cmdBeginRenderPass(cmdbuf, &.{
            .render_pass = self.render_pass_texture_target,
            .framebuffer = tt.framebuffer,
            .render_area = c.vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = tt.fb_size,
            },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        }, .@"inline");
        dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
    }
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

const TextureTarget = struct {
    tex_idx: TextureIdx = 0,
    fb_size: c.vk.Extent2D = .{ .width = 0, .height = 0 },
    framebuffer: c.vk.Framebuffer = null,

    fn isNull(self: @This()) bool {
        return self.framebuffer == null;
    }
};

const Texture = struct {
    img: c.vk.Image = null,
    img_view: c.vk.ImageView = null,
    mem: c.vk.DeviceMemory = null,
    dset: c.vk.DescriptorSet = null,

    trace: Trace = Trace.init,
    const Trace = std.debug.ConfigurableTrace(6, 5, texture_tracing);

    pub fn isNull(self: @This()) bool {
        return self.dset == null;
    }

    pub fn deinit(tex: Texture, b: *Backend) void {
        const dev = b.dev;
        const vk_alloc = b.vk_alloc;
        dev.freeDescriptorSets(b.dpool, 1, &[_]c.vk.DescriptorSet{tex.dset}) catch |err| slog.err("Failed to free descriptor set: {}", .{err});
        dev.destroyImageView(tex.img_view, vk_alloc);
        dev.destroyImage(tex.img, vk_alloc);
        dev.freeMemory(tex.mem, vk_alloc);
    }
};

fn createPipeline(
    dev: c.vk.Device,
    layout: c.vk.PipelineLayout,
    render_pass: c.vk.RenderPass,
    vk_alloc: ?*c.vk.AllocationCallbacks,
) !c.vk.Pipeline {
    //  NOTE: VK_KHR_maintenance5 (which was promoted to vulkan 1.4) deprecates ShaderModules.
    // todo: check for extension and then enable
    const ext_m5 = false; // VK_KHR_maintenance5

    const vert_shdd = std.mem.zeroInit(c.vk.ShaderModuleCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = vs_spv.len,
        .pCode = @ptrCast(&vs_spv),
    });
    const shader_module: c.vk.ShaderModule = if (ext_m5) {
        var module: c.vk.ShaderModule = undefined;
        try check_vk(c.vk.CreateShaderModule(dev, &vert_shdd, vk_alloc, &module));
        module;
    } else null;

    const frag_shdd = std.mem.zeroInit(c.vk.ShaderModuleCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = fs_spv.len,
        .pCode = @ptrCast(&fs_spv),
    });

    var pssci = [_]c.vk.PipelineShaderStageCreateInfo{
        .{std.mem.zeroInit(c.vk.PipelineShaderStageCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.vk.SHADER_STAGE_VERTEX_BIT,
            .module = shader_module,
            .pNext = if (ext_m5) &vert_shdd else null,
            .pName = "main",
        })},
        .{std.mem.zeroInit(c.vk.PipelineShaderStageCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.vk.SHADER_STAGE_FRAGMENT_BIT,
            //.module = frag,
            .pNext = if (ext_m5) &frag_shdd else null,
            .pName = "main",
        })},
    };
    defer if (!ext_m5) for (pssci) |p| if (p.module != null) {
        c.vk.DestroyShaderModule(dev, p.module, vk_alloc);
    };

    const pvisci = c.vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = VertexBindings.binding_description.len,
        .p_vertex_binding_descriptions = &VertexBindings.binding_description,
        .vertex_attribute_description_count = VertexBindings.attribute_description.len,
        .p_vertex_attribute_descriptions = &VertexBindings.attribute_description,
    };

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
        .pViewports = @ptrCast(&viewport), // set in createCommandBuffers with cmdSetViewport
        .scissorCount = 1,
        .pScissors = @ptrCast(&scissor), // set in createCommandBuffers with cmdSetScissor
    });

    const prsci = std.mem.zeroInit(c.vk.PipelineRasterizationStateCreateInfo, .{
        .depthClampEnable = c.vk.FALSE,
        .rasterizerDiscardEnable = c.vk.FALSE,
        .polygonMode = c.vk.POLYGON_MODE_FILL,
        .cullMode = c.vk.CULL_MODE_NONE,
        .frontFace = c.vk.FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = c.vk.FALSE,
        .depthBiasConstant_factor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlope_factor = 0,
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
        .pAttachments = @ptrCast(&pcbas),
        .blendConstants = &[_]f32{ 0, 0, 0, 0 },
    });

    const dynstate = [_]c.vk.DynamicState{
        c.vk.DYNAMIC_STATE_VIEWPORT,
        c.vk.DYNAMIC_STATE_SCISSOR,
    };
    const pdsci = c.vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    const gpci = c.vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stageCount = pssci.len,
        .pStages = &pssci,
        .pVertexInputState = &pvisci,
        .pInputAssemblyState = &piasci,
        .pTessellationState = null,
        .pViewportState = &pvsci,
        .pRasterizationState = &prsci,
        .pMultisampleState = &pmsci,
        .pDepthStencilState = null,
        .pColorBlendState = &pcbsci,
        .pDynamicState = &pdsci,
        .layout = layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    var pipeline: c.vk.Pipeline = undefined;
    try check_vk(c.vk.CreateGraphicsPipelines(
        null,
        1,
        @ptrCast(&gpci),
        vk_alloc,
        @ptrCast(&pipeline),
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
    const buf = self.dev.createBuffer(&buf_info, self.vk_alloc) catch |err| {
        slog.err("createBuffer: {}", .{err});
        return err;
    };
    errdefer self.dev.destroyBuffer(buf, self.vk_alloc);
    const mreq = self.dev.getBufferMemoryRequirements(buf);
    const mem = try self.dev.allocateMemory(&.{ .allocation_size = mreq.size, .memory_type_index = self.host_vis_mem_idx }, self.vk_alloc);
    errdefer self.dev.freeMemory(mem, self.vk_alloc);
    const mem_offset = 0;
    try self.dev.bindBufferMemory(buf, mem, mem_offset);
    const data = @as([*]u8, @ptrCast((try self.dev.mapMemory(mem, mem_offset, c.vk.WHOLE_SIZE, .{})).?))[0..mreq.size];
    @memcpy(data[0..contents.len], contents);
    if (!self.host_vis_coherent)
        try self.dev.flushMappedMemoryRanges(1, &.{.{ .memory = mem, .offset = mem_offset, .size = mreq.size }});
    return .{ .buf = buf, .mem = mem };
}

pub fn beginSingleTimeCommands(self: *Self) !c.vk.CommandBuffer {
    if (self.cpool_lock) |l| l.lockCB(l.lock_userdata);
    defer if (self.cpool_lock) |l| l.unlockCB(l.lock_userdata);

    var cmdbuf: c.vk.CommandBuffer = undefined;
    self.dev.allocateCommandBuffers(&.{
        .command_pool = self.cpool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf)) catch |err| {
        if (enable_breakpoints) @breakpoint();
        return err;
    };
    try self.dev.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });
    return cmdbuf;
}

pub fn endSingleTimeCommands(self: *Self, cmdbuf: c.vk.CommandBuffer) !void {
    try self.dev.endCommandBuffer(cmdbuf);
    defer self.dev.freeCommandBuffers(self.cpool, 1, @ptrCast(&cmdbuf));

    if (self.queue_lock) |l| l.lockCB(l.lock_userdata);
    defer if (self.queue_lock) |l| l.unlockCB(l.lock_userdata);
    const qs = [_]c.vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = null,
        .p_wait_dst_stage_mask = null,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = null,
    }};
    try self.dev.queueSubmit(self.queue, 1, &qs, null);
    // TODO: is there better way to sync this than stalling the queue? barriers or something
    self.dev.queueWaitIdle(self.queue) catch |err| {
        slog.warn("queueWaitIdle failed: {}", .{err});
    };
}

pub fn createTextureWithMem(self: Backend, img_info: c.vk.ImageCreateInfo, interpolation: dvui.enums.TextureInterpolation) !Texture {
    const dev = self.dev;

    const img: c.vk.Image = try dev.createImage(&img_info, self.vk_alloc);
    errdefer dev.destroyImage(img, self.vk_alloc);
    const mreq = dev.getImageMemoryRequirements(img);

    const mem = dev.allocateMemory(&.{
        .allocation_size = mreq.size,
        .memory_type_index = self.device_local_mem_idx,
    }, self.vk_alloc) catch |err| {
        slog.err("Failed to alloc texture mem: {}", .{err});
        return err;
    };
    errdefer dev.freeMemory(mem, self.vk_alloc);
    try dev.bindImageMemory(img, mem, 0);

    const srr = c.vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
    const img_view = try dev.createImageView(&.{
        .flags = .{},
        .image = img,
        .view_type = .@"2d",
        .format = img_format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = srr,
    }, self.vk_alloc);
    errdefer dev.destroyImageView(img_view, self.vk_alloc);

    var dset: [1]c.vk.DescriptorSet = undefined;
    dev.allocateDescriptorSets(&.{
        .descriptor_pool = self.dpool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&self.dset_layout),
    }, &dset) catch |err| {
        if (enable_breakpoints) @breakpoint();
        slog.err("Failed to allocate descriptor set: {}", .{err});
        return err;
    };
    const dii = [1]c.vk.DescriptorImageInfo{.{
        .sampler = self.samplers[@intFromEnum(interpolation)],
        .image_view = img_view,
        .image_layout = .shader_read_only_optimal,
    }};
    const write_dss = [_]c.vk.WriteDescriptorSet{.{
        .dst_set = dset[0],
        .dst_binding = tex_binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = &dii,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }};
    dev.updateDescriptorSets(write_dss.len, &write_dss, 0, null);

    return Texture{ .img = img, .img_view = img_view, .mem = mem, .dset = dset[0] };
}

pub fn createAndUplaodTexture(self: *Backend, pixels: [*]const u8, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !Texture {
    //slog.info("img {}x{}; req size {}", .{ width, height, mreq.size });
    const tex = try self.createTextureWithMem(.{
        //.format = .b8g8r8_unorm,
        .image_type = .@"2d",
        .format = img_format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{
            .transfer_dst_bit = true,
            .sampled_bit = true,
        },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, interpolation);
    errdefer tex.deinit(self);
    const dev = self.dev;
    var cmdbuf = try self.beginSingleTimeCommands();
    // TODO: review what error handling should be optimal - if anything fails we should discard cmdbuf not submit it
    defer self.endSingleTimeCommands(cmdbuf) catch unreachable;

    const mreq = dev.getImageMemoryRequirements(tex.img);
    const img_staging = try self.stageToBuffer(.{
        .flags = .{},
        .size = mreq.size,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, pixels[0 .. width * height * 4]);
    defer dev.destroyBuffer(img_staging.buf, self.vk_alloc);
    defer dev.freeMemory(img_staging.mem, self.vk_alloc);

    const srr = c.vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
    { // transition image to dst_optimal
        const img_barrier = c.vk.ImageMemoryBarrier{
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = c.vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = c.vk.QUEUE_FAMILY_IGNORED,
            .image = tex.img,
            .subresource_range = srr,
        };
        dev.cmdPipelineBarrier(cmdbuf, .{ .host_bit = true, .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&img_barrier));

        try self.endSingleTimeCommands(cmdbuf);
        cmdbuf = try self.beginSingleTimeCommands();
    }
    { // copy staging -> img
        const buff_img_copy = c.vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        };
        dev.cmdCopyBufferToImage(cmdbuf, img_staging.buf, tex.img, .transfer_dst_optimal, 1, @ptrCast(&buff_img_copy));

        try self.endSingleTimeCommands(cmdbuf);
        cmdbuf = try self.beginSingleTimeCommands();
    }
    { // transition to read only optimal
        const img_barrier = c.vk.ImageMemoryBarrier{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = c.vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = c.vk.QUEUE_FAMILY_IGNORED,
            .image = tex.img,
            .subresource_range = srr,
        };
        dev.cmdPipelineBarrier(cmdbuf, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&img_barrier));

        try self.endSingleTimeCommands(cmdbuf);
        cmdbuf = try self.beginSingleTimeCommands();
    }

    return tex;
}

pub fn createRenderPass(dev: c.vk.Device, format: c.vk.Format) !c.vk.RenderPass {
    var color_attachments: [1]c.vk.AttachmentDescription = undefined;
    var subpasses: [1]c.vk.SubpassDescription = undefined;

    { // Render to framebuffer
        color_attachments[0] = std.mem.zeroInit(c.vk.AttachmentDescription, .{
            .format = format, // swapchain / framebuffer image format
            .samples = c.vk.SAMPLE_COUNT_1_BIT,
            .loadOp = c.vk.ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.vk.ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.vk.ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.vk.ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.vk.IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
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
        .input_rate = .vertex,
    }};

    const attribute_description = [_]c.vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r8g8b8a8_unorm,
            .offset = @offsetOf(Vertex, "col"),
        },
        .{
            .binding = 0,
            .location = 2,
            .format = .r32g32_sfloat,
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
