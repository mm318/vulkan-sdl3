const std = @import("std");

pub const c = @import("vulkan").c;

const vki = @import("vulkan");
const check_vk = vki.check_vk;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const Vertex = mesh_mod.Vertex;

pub const dvui = @import("dvui");
const DvuiBackend = dvui.backend;

const math3d = @import("math3d.zig");
pub const Vec2 = math3d.Vec2;
pub const Vec3 = math3d.Vec3;
pub const Vec4 = math3d.Vec4;
pub const Mat4 = math3d.Mat4;

// const texs = @import("textures.zig");
// const Texture = texs.Texture;

const log = std.log.scoped(.vulkan_engine);

const Self = @This();

const App = struct {
    context: *anyopaque,
    run_app_fn: *const fn (_: *anyopaque, _: u64) void,
    draw_contents_fn: *const fn (_: *anyopaque, _: *Self) void,
    draw_ui_fn: *const fn (_: *anyopaque, _: *dvui.Window) void,

    fn run_app(self: App, current_time: u64) void {
        self.run_app_fn(self.context, current_time);
    }

    fn draw_contents(self: App, engine: *Self) void {
        self.draw_contents_fn(self.context, engine);
    }

    fn draw_ui(self: App, window: *dvui.Window) void {
        self.draw_ui_fn(self.context, window);
    }
};

const VK_NULL_HANDLE = null;

// TODO: make non-public
pub const AllocatedBuffer = struct {
    buffer: c.vk.Buffer,
    allocation: c.vma.Allocation,
};

const AllocatedImage = struct {
    image: c.vk.Image,
    allocation: c.vma.Allocation,
};

// Scene management
const Material = struct {
    texture_set: c.vk.DescriptorSet = VK_NULL_HANDLE,
    pipeline: c.vk.Pipeline,
    pipeline_layout: c.vk.PipelineLayout,
};

pub const RenderObject = struct {
    mesh: *const Mesh,
    material: *const Material,
    transform: Mat4,
};

const FrameData = struct {
    swapchain_semaphore: c.vk.Semaphore = VK_NULL_HANDLE,
    render_fence: c.vk.Fence = VK_NULL_HANDLE,
    command_pool: c.vk.CommandPool = VK_NULL_HANDLE,
    main_command_buffer: c.vk.CommandBuffer = VK_NULL_HANDLE,

    object_buffer: AllocatedBuffer = .{ .buffer = VK_NULL_HANDLE, .allocation = VK_NULL_HANDLE },
    object_descriptor_set: c.vk.DescriptorSet = VK_NULL_HANDLE,
};

const GPUCameraData = struct {
    view: Mat4,
    proj: Mat4,
    view_proj: Mat4,
};

const GPUSceneData = struct {
    fog_color: Vec4,
    fog_distance: Vec4, // x = start, y = end
    ambient_color: Vec4,
    sunlight_dir: Vec4,
    sunlight_color: Vec4,
};

const GPUObjectData = struct {
    model_matrix: Mat4,
};

const UploadContext = struct {
    upload_fence: c.vk.Fence = VK_NULL_HANDLE,
    command_pool: c.vk.CommandPool = VK_NULL_HANDLE,
    command_buffer: c.vk.CommandBuffer = VK_NULL_HANDLE,
};

const MeshPushConstants = struct {
    data: Vec4,
    render_matrix: Mat4,
};

const VulkanDeleter = struct {
    object: ?*anyopaque,
    delete_fn: *const fn (entry: *VulkanDeleter, self: *Self) void,

    fn delete(self: *VulkanDeleter, engine: *Self) void {
        self.delete_fn(self, engine);
    }

    fn make(object: anytype, func: anytype) VulkanDeleter {
        const T = @TypeOf(object);
        comptime {
            std.debug.assert(@typeInfo(T) == .optional);
            const Ptr = @typeInfo(T).optional.child;
            std.debug.assert(@typeInfo(Ptr) == .pointer);
            std.debug.assert(@typeInfo(Ptr).pointer.size == .one);

            const Fn = @TypeOf(func);
            std.debug.assert(@typeInfo(Fn) == .@"fn");
        }

        return VulkanDeleter{
            .object = object,
            .delete_fn = struct {
                fn destroy_impl(entry: *VulkanDeleter, self: *Self) void {
                    const obj: @TypeOf(object) = @ptrCast(entry.object);
                    func(self.device, obj, vk_alloc_cbs);
                }
            }.destroy_impl,
        };
    }
};

const VmaBufferDeleter = struct {
    buffer: AllocatedBuffer,

    fn delete(self: *VmaBufferDeleter, engine: *Self) void {
        c.vma.DestroyBuffer(engine.vma_allocator, self.buffer.buffer, self.buffer.allocation);
    }
};

const VmaImageDeleter = struct {
    image: AllocatedImage,

    fn delete(self: *VmaImageDeleter, engine: *Self) void {
        c.vma.DestroyImage(engine.vma_allocator, self.image.image, self.image.allocation);
    }
};

const FRAME_OVERLAP = 2;

const vk_alloc_cbs: ?*c.vk.AllocationCallbacks = null;

//
// Data
//

// Keep this around for long standing allocations
allocator: std.mem.Allocator = undefined,

// App data
app: App,

// SDL data
frame_number: i32 = 0,
sdl_window: *c.SDL.Window = undefined,

// Vulkan data
instance: c.vk.Instance = VK_NULL_HANDLE,
debug_messenger: c.vk.DebugUtilsMessengerEXT = VK_NULL_HANDLE,

physical_device: c.vk.PhysicalDevice = VK_NULL_HANDLE,
physical_device_properties: c.vk.PhysicalDeviceProperties = undefined,

device: c.vk.Device = VK_NULL_HANDLE,
surface: c.vk.SurfaceKHR = VK_NULL_HANDLE,

swapchain: c.vk.SwapchainKHR = VK_NULL_HANDLE,
swapchain_format: c.vk.Format = undefined,
swapchain_extent: c.vk.Extent2D = undefined,
swapchain_images: []c.vk.Image = undefined,
swapchain_image_views: []c.vk.ImageView = undefined,

graphics_queue: c.vk.Queue = VK_NULL_HANDLE,
graphics_queue_family: u32 = undefined,
present_queue: c.vk.Queue = VK_NULL_HANDLE,
present_queue_family: u32 = undefined,

render_pass: c.vk.RenderPass = VK_NULL_HANDLE,
framebuffers: []c.vk.Framebuffer = undefined,

depth_image_view: c.vk.ImageView = VK_NULL_HANDLE,
depth_image: AllocatedImage = undefined,
depth_format: c.vk.Format = undefined,

upload_context: UploadContext = .{},

frames: [FRAME_OVERLAP]FrameData = .{FrameData{}} ** FRAME_OVERLAP,
present_semaphores: std.ArrayList(c.vk.Semaphore) = undefined,

camera_and_scene_set: c.vk.DescriptorSet = VK_NULL_HANDLE,
camera_and_scene_buffer: AllocatedBuffer = undefined,

global_set_layout: c.vk.DescriptorSetLayout = VK_NULL_HANDLE,
object_set_layout: c.vk.DescriptorSetLayout = VK_NULL_HANDLE,
descriptor_pool: c.vk.DescriptorPool = VK_NULL_HANDLE,

vma_allocator: c.vma.Allocator = undefined,

// rendering data for drawing stuff
mesh_pipeline: c.vk.Pipeline = VK_NULL_HANDLE,
mesh_pipeline_layout: c.vk.PipelineLayout = VK_NULL_HANDLE,
quad_mesh: Mesh = undefined,
material: Material = undefined,
current_cmd: c.vk.CommandBuffer = VK_NULL_HANDLE,

deletion_queue: std.ArrayList(VulkanDeleter) = undefined,
buffer_deletion_queue: std.ArrayList(VmaBufferDeleter) = undefined,
image_deletion_queue: std.ArrayList(VmaImageDeleter) = undefined,

// UI data
dvui_window: ?dvui.Window = null,

pub fn init(
    a: std.mem.Allocator,
    size: c.vk.Extent2D,
    comptime AppContext: type,
    app_context: *AppContext,
    comptime run_app: *const fn (_: *AppContext, _: u64) void,
    comptime draw_contents: *const fn (_: *AppContext, _: *Self) void,
    comptime draw_ui: *const fn (_: *AppContext, _: *dvui.Window) void,
) Self {
    const ThisApp = struct {
        fn _run_app(ctx: *anyopaque, current_time: u64) void {
            const context: *AppContext = @ptrCast(@alignCast(ctx));
            return run_app(context, current_time);
        }

        fn _draw_contents(ctx: *anyopaque, engine: *Self) void {
            const context: *AppContext = @ptrCast(@alignCast(ctx));
            return draw_contents(context, engine);
        }

        fn _draw_ui(ctx: *anyopaque, window: *dvui.Window) void {
            const context: *AppContext = @ptrCast(@alignCast(ctx));
            return draw_ui(context, window);
        }
    };

    check_sdl(c.SDL.Init(c.SDL.INIT_VIDEO));

    const window = c.SDL.CreateWindow(
        "Vulkan",
        @intCast(size.width),
        @intCast(size.height),
        c.SDL.WINDOW_VULKAN | c.SDL.WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse @panic("Failed to create SDL window");

    _ = c.SDL.ShowWindow(window);

    var engine = Self{
        .allocator = a,
        .app = .{
            .context = app_context,
            .run_app_fn = ThisApp._run_app,
            .draw_contents_fn = ThisApp._draw_contents,
            .draw_ui_fn = ThisApp._draw_ui,
        },
        .sdl_window = window,
        .deletion_queue = std.ArrayList(VulkanDeleter){},
        .buffer_deletion_queue = std.ArrayList(VmaBufferDeleter){},
        .image_deletion_queue = std.ArrayList(VmaImageDeleter){},
    };

    engine.init_instance();

    // Create the window surface
    check_sdl(c.SDL.Vulkan_CreateSurface(window, engine.instance, vk_alloc_cbs, &engine.surface));

    engine.init_device();

    // Create a VMA allocator
    const allocator_ci = std.mem.zeroInit(c.vma.AllocatorCreateInfo, .{
        .physicalDevice = engine.physical_device,
        .device = engine.device,
        .instance = engine.instance,
    });
    check_vk(c.vma.CreateAllocator(&allocator_ci, &engine.vma_allocator)) catch @panic("Failed to create VMA allocator");

    engine.init_swapchain();
    engine.init_commands();
    engine.init_default_renderpass();
    engine.init_framebuffers();
    engine.init_sync_structures();
    engine.init_descriptors();
    engine.init_pipelines();
    engine.load_meshes();
    engine.init_gui();

    return engine;
}

fn init_instance(self: *Self) void {
    var sdl_required_extension_count: u32 = undefined;
    const sdl_extensions = c.SDL.Vulkan_GetInstanceExtensions(&sdl_required_extension_count);
    const sdl_extension_slice = sdl_extensions[0..sdl_required_extension_count];

    // Instance creation and optional debug utilities
    const instance = vki.create_instance(std.heap.page_allocator, .{
        .application_name = "VkGuide",
        .application_version = c.vk.MAKE_VERSION(0, 1, 0),
        .engine_name = "VkGuide",
        .engine_version = c.vk.MAKE_VERSION(0, 1, 0),
        .api_version = c.vk.MAKE_VERSION(1, 4, 0),
        .debug = true,
        .required_extensions = sdl_extension_slice,
    }) catch |err| {
        log.err("Failed to create vulkan instance with error: {s}", .{@errorName(err)});
        unreachable;
    };

    self.instance = instance.handle;
    self.debug_messenger = instance.debug_messenger;
}

fn init_device(self: *Self) void {
    // Physical device selection
    const required_device_extensions: []const [*c]const u8 = &.{
        "VK_KHR_swapchain",
    };

    const physical_device = vki.select_physical_device(std.heap.page_allocator, self.instance, .{
        .min_api_version = c.vk.MAKE_VERSION(1, 4, 0),
        .required_extensions = required_device_extensions,
        .surface = self.surface,
        .criteria = .PreferDiscrete,
    }) catch |err| {
        log.err("Failed to select physical device with error: {s}", .{@errorName(err)});
        unreachable;
    };

    self.physical_device = physical_device.handle;
    self.physical_device_properties = physical_device.properties;

    log.info(
        "The GPU has a minimum buffer alignment of {} bytes",
        .{physical_device.properties.limits.minUniformBufferOffsetAlignment},
    );

    self.graphics_queue_family = physical_device.graphics_queue_family;
    self.present_queue_family = physical_device.present_queue_family;

    const shader_draw_parameters_features = std.mem.zeroInit(c.vk.PhysicalDeviceShaderDrawParametersFeatures, .{
        .sType = c.vk.STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES,
        .shaderDrawParameters = c.vk.TRUE,
    });

    // Create a logical device
    const device = vki.create_logical_device(self.allocator, .{
        .physical_device = physical_device,
        .features = std.mem.zeroInit(c.vk.PhysicalDeviceFeatures, .{}),
        .alloc_cb = vk_alloc_cbs,
        .pnext = &shader_draw_parameters_features,
    }) catch @panic("Failed to create logical device");

    self.device = device.handle;
    self.graphics_queue = device.graphics_queue;
    self.present_queue = device.present_queue;
}

fn init_swapchain(self: *Self) void {
    var win_width: c_int = undefined;
    var win_height: c_int = undefined;
    check_sdl(c.SDL.GetWindowSizeInPixels(self.sdl_window, &win_width, &win_height));

    // Create a swapchain
    const swapchain = vki.create_swapchain(self.allocator, .{
        .physical_device = self.physical_device,
        .graphics_queue_family = self.graphics_queue_family,
        .present_queue_family = self.graphics_queue_family,
        .device = self.device,
        .surface = self.surface,
        .old_swapchain = null,
        .vsync = true,
        .window_width = @intCast(win_width),
        .window_height = @intCast(win_height),
        .alloc_cb = vk_alloc_cbs,
    }) catch @panic("Failed to create swapchain");

    self.swapchain = swapchain.handle;
    self.swapchain_format = swapchain.format;
    self.swapchain_extent = swapchain.extent;
    self.swapchain_images = swapchain.images;
    self.swapchain_image_views = swapchain.image_views;

    for (self.swapchain_image_views) |view| {
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(view, c.vk.DestroyImageView),
        ) catch @panic("Out of memory");
    }
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(swapchain.handle, c.vk.DestroySwapchainKHR),
    ) catch @panic("Out of memory");

    log.info("Created swapchain, extent = {}", .{self.swapchain_extent});

    // Create depth image to associate with the swapchain
    const extent = c.vk.Extent3D{
        .width = self.swapchain_extent.width,
        .height = self.swapchain_extent.height,
        .depth = 1,
    };

    // Hard-coded 32-bit float depth format
    self.depth_format = c.vk.FORMAT_D32_SFLOAT;

    const depth_image_ci = std.mem.zeroInit(c.vk.ImageCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.vk.IMAGE_TYPE_2D,
        .format = self.depth_format,
        .extent = extent,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.vk.SAMPLE_COUNT_1_BIT,
        .tiling = c.vk.IMAGE_TILING_OPTIMAL,
        .usage = c.vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        .sharingMode = c.vk.SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.vk.IMAGE_LAYOUT_UNDEFINED,
    });

    const depth_image_ai = std.mem.zeroInit(c.vma.AllocationCreateInfo, .{
        .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
        .requiredFlags = c.vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    });

    check_vk(c.vma.CreateImage(
        self.vma_allocator,
        &depth_image_ci,
        &depth_image_ai,
        &self.depth_image.image,
        &self.depth_image.allocation,
        null,
    )) catch @panic("Failed to create depth image");

    const depth_image_view_ci = std.mem.zeroInit(c.vk.ImageViewCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = self.depth_image.image,
        .viewType = c.vk.IMAGE_VIEW_TYPE_2D,
        .format = self.depth_format,
        .subresourceRange = .{
            .aspectMask = c.vk.IMAGE_ASPECT_DEPTH_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    });

    check_vk(c.vk.CreateImageView(self.device, &depth_image_view_ci, vk_alloc_cbs, &self.depth_image_view)) catch @panic("Failed to create depth image view");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.depth_image_view, c.vk.DestroyImageView),
    ) catch @panic("Out of memory");
    self.image_deletion_queue.append(
        self.allocator,
        VmaImageDeleter{ .image = self.depth_image },
    ) catch @panic("Out of memory");

    log.info("Created depth image", .{});
}

fn init_commands(self: *Self) void {
    // Create a command pool
    const command_pool_ci = std.mem.zeroInit(c.vk.CommandPoolCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.graphics_queue_family,
    });

    for (&self.frames) |*frame| {
        check_vk(c.vk.CreateCommandPool(self.device, &command_pool_ci, vk_alloc_cbs, &frame.command_pool)) catch log.err("Failed to create command pool", .{});
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(frame.command_pool, c.vk.DestroyCommandPool),
        ) catch @panic("Out of memory");

        // Allocate a command buffer from the command pool
        const command_buffer_ai = std.mem.zeroInit(c.vk.CommandBufferAllocateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = frame.command_pool,
            .level = c.vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        });

        check_vk(c.vk.AllocateCommandBuffers(self.device, &command_buffer_ai, &frame.main_command_buffer)) catch @panic("Failed to allocate command buffer");

        log.info("Created command pool and command buffer", .{});
    }

    // =================================
    // Upload context
    //

    // For the time being this is submitting on the graphics queue
    const upload_command_pool_ci = std.mem.zeroInit(c.vk.CommandPoolCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = 0,
        .queueFamilyIndex = self.graphics_queue_family,
    });

    check_vk(c.vk.CreateCommandPool(self.device, &upload_command_pool_ci, vk_alloc_cbs, &self.upload_context.command_pool)) catch @panic("Failed to create upload command pool");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.upload_context.command_pool, c.vk.DestroyCommandPool),
    ) catch @panic("Out of memory");

    const upload_command_buffer_ai = std.mem.zeroInit(c.vk.CommandBufferAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.upload_context.command_pool,
        .level = c.vk.COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    });

    check_vk(c.vk.AllocateCommandBuffers(self.device, &upload_command_buffer_ai, &self.upload_context.command_buffer)) catch @panic("Failed to allocate upload command buffer");
}

fn init_default_renderpass(self: *Self) void {
    // Color attachement
    const color_attachment = std.mem.zeroInit(c.vk.AttachmentDescription, .{
        .format = self.swapchain_format,
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

    // Depth attachment
    const depth_attachment = std.mem.zeroInit(c.vk.AttachmentDescription, .{
        .format = self.depth_format,
        .samples = c.vk.SAMPLE_COUNT_1_BIT,
        .loadOp = c.vk.ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.vk.ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.vk.IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    });

    const depth_attachement_ref = std.mem.zeroInit(c.vk.AttachmentReference, .{
        .attachment = 1,
        .layout = c.vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    });

    // Subpass
    const subpass = std.mem.zeroInit(c.vk.SubpassDescription, .{
        .pipelineBindPoint = c.vk.PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
        .pDepthStencilAttachment = &depth_attachement_ref,
    });

    const attachment_descriptions = [_]c.vk.AttachmentDescription{
        color_attachment,
        depth_attachment,
    };

    // Subpass color and depth depencies
    const color_dependency = std.mem.zeroInit(c.vk.SubpassDependency, .{
        .srcSubpass = c.vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = c.vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = c.vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    });

    const depth_dependency = std.mem.zeroInit(c.vk.SubpassDependency, .{
        .srcSubpass = c.vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = c.vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = c.vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .dstAccessMask = c.vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    });

    const dependecies = [_]c.vk.SubpassDependency{
        color_dependency,
        depth_dependency,
    };

    const render_pass_create_info = std.mem.zeroInit(c.vk.RenderPassCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = @as(u32, @intCast(attachment_descriptions.len)),
        .pAttachments = attachment_descriptions[0..].ptr,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = @as(u32, @intCast(dependecies.len)),
        .pDependencies = &dependecies,
    });

    check_vk(c.vk.CreateRenderPass(self.device, &render_pass_create_info, vk_alloc_cbs, &self.render_pass)) catch @panic("Failed to create render pass");
    self.deletion_queue.append(self.allocator, VulkanDeleter.make(self.render_pass, c.vk.DestroyRenderPass)) catch @panic("Out of memory");

    log.info("Created render pass", .{});
}

fn init_framebuffers(self: *Self) void {
    var framebuffer_ci = std.mem.zeroInit(c.vk.FramebufferCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = self.render_pass,
        .attachmentCount = 2,
        .width = self.swapchain_extent.width,
        .height = self.swapchain_extent.height,
        .layers = 1,
    });

    self.framebuffers = self.allocator.alloc(c.vk.Framebuffer, self.swapchain_image_views.len) catch @panic("Out of memory");

    for (self.swapchain_image_views, self.framebuffers) |view, *framebuffer| {
        const attachements = [2]c.vk.ImageView{
            view,
            self.depth_image_view,
        };
        framebuffer_ci.pAttachments = &attachements;
        check_vk(c.vk.CreateFramebuffer(self.device, &framebuffer_ci, vk_alloc_cbs, framebuffer)) catch @panic("Failed to create framebuffer");
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(framebuffer.*, c.vk.DestroyFramebuffer),
        ) catch @panic("Out of memory");
    }

    log.info("Created {} framebuffers", .{self.framebuffers.len});
}

fn init_sync_structures(self: *Self) void {
    const semaphore_ci = std.mem.zeroInit(c.vk.SemaphoreCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    });

    const fence_ci = std.mem.zeroInit(c.vk.FenceCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.vk.FENCE_CREATE_SIGNALED_BIT,
    });

    self.present_semaphores.ensureTotalCapacity(
        self.allocator,
        self.swapchain_images.len,
    ) catch @panic("Out of memory");

    for (0..self.swapchain_images.len) |_| {
        var semaphore: c.vk.Semaphore = VK_NULL_HANDLE;
        check_vk(c.vk.CreateSemaphore(self.device, &semaphore_ci, vk_alloc_cbs, &semaphore)) catch @panic("Failed to create present semaphore");
        self.present_semaphores.append(
            self.allocator,
            semaphore,
        ) catch @panic("Out of memory");
    }

    for (self.present_semaphores.items) |sema| {
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(sema, c.vk.DestroySemaphore),
        ) catch @panic("Out of memory");
    }

    for (&self.frames) |*frame| {
        check_vk(c.vk.CreateSemaphore(self.device, &semaphore_ci, vk_alloc_cbs, &frame.swapchain_semaphore)) catch @panic("Failed to create render semaphore");
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(frame.swapchain_semaphore, c.vk.DestroySemaphore),
        ) catch @panic("Out of memory");

        check_vk(c.vk.CreateFence(self.device, &fence_ci, vk_alloc_cbs, &frame.render_fence)) catch @panic("Failed to create render fence");
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(frame.render_fence, c.vk.DestroyFence),
        ) catch @panic("Out of memory");
    }

    // Upload context
    const upload_fence_ci = std.mem.zeroInit(c.vk.FenceCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
    });

    check_vk(c.vk.CreateFence(self.device, &upload_fence_ci, vk_alloc_cbs, &self.upload_context.upload_fence)) catch @panic("Failed to create upload fence");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.upload_context.upload_fence, c.vk.DestroyFence),
    ) catch @panic("Out of memory");

    log.info("Created sync structures", .{});
}

const PipelineBuilder = struct {
    shader_stages: []c.vk.PipelineShaderStageCreateInfo,
    vertex_input_state: c.vk.PipelineVertexInputStateCreateInfo,
    input_assembly_state: c.vk.PipelineInputAssemblyStateCreateInfo,
    viewport: c.vk.Viewport,
    scissor: c.vk.Rect2D,
    rasterization_state: c.vk.PipelineRasterizationStateCreateInfo,
    color_blend_attachment_state: c.vk.PipelineColorBlendAttachmentState,
    multisample_state: c.vk.PipelineMultisampleStateCreateInfo,
    pipeline_layout: c.vk.PipelineLayout,
    depth_stencil_state: c.vk.PipelineDepthStencilStateCreateInfo,

    fn build(self: PipelineBuilder, device: c.vk.Device, render_pass: c.vk.RenderPass) c.vk.Pipeline {
        const viewport_state = std.mem.zeroInit(c.vk.PipelineViewportStateCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &self.viewport,
            .scissorCount = 1,
            .pScissors = &self.scissor,
        });

        const color_blend_state = std.mem.zeroInit(c.vk.PipelineColorBlendStateCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = c.vk.FALSE,
            .logicOp = c.vk.LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &self.color_blend_attachment_state,
        });

        const pipeline_ci = std.mem.zeroInit(c.vk.GraphicsPipelineCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = @as(u32, @intCast(self.shader_stages.len)),
            .pStages = self.shader_stages.ptr,
            .pVertexInputState = &self.vertex_input_state,
            .pInputAssemblyState = &self.input_assembly_state,
            .pViewportState = &viewport_state,
            .pRasterizationState = &self.rasterization_state,
            .pMultisampleState = &self.multisample_state,
            .pColorBlendState = &color_blend_state,
            .pDepthStencilState = &self.depth_stencil_state,
            .layout = self.pipeline_layout,
            .renderPass = render_pass,
            .subpass = 0,
            .basePipelineHandle = VK_NULL_HANDLE,
        });

        var pipeline: c.vk.Pipeline = undefined;
        check_vk(c.vk.CreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeline_ci, vk_alloc_cbs, &pipeline)) catch {
            log.err("Failed to create graphics pipeline", .{});
            return VK_NULL_HANDLE;
        };

        return pipeline;
    }
};

fn init_pipelines(self: *Self) void {
    // Create pipeline for meshes
    const vertex_descritpion = mesh_mod.Vertex.vertex_input_description;

    const vertex_input_state_ci = std.mem.zeroInit(c.vk.PipelineVertexInputStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pVertexAttributeDescriptions = vertex_descritpion.attributes.ptr,
        .vertexAttributeDescriptionCount = @as(u32, @intCast(vertex_descritpion.attributes.len)),
        .pVertexBindingDescriptions = vertex_descritpion.bindings.ptr,
        .vertexBindingDescriptionCount = @as(u32, @intCast(vertex_descritpion.bindings.len)),
    });

    const input_assembly_state_ci = std.mem.zeroInit(c.vk.PipelineInputAssemblyStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = c.vk.FALSE,
    });

    const rasterization_state_ci = std.mem.zeroInit(c.vk.PipelineRasterizationStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.vk.POLYGON_MODE_FILL,
        .cullMode = c.vk.CULL_MODE_NONE,
        .frontFace = c.vk.FRONT_FACE_CLOCKWISE,
        .lineWidth = 1.0,
    });

    const multisample_state_ci = std.mem.zeroInit(c.vk.PipelineMultisampleStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = c.vk.SAMPLE_COUNT_1_BIT,
        .minSampleShading = 1.0,
    });

    const depth_stencil_state_ci = std.mem.zeroInit(c.vk.PipelineDepthStencilStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = c.vk.TRUE,
        .depthWriteEnable = c.vk.TRUE,
        .depthCompareOp = c.vk.COMPARE_OP_LESS_OR_EQUAL,
        .depthBoundsTestEnable = c.vk.FALSE,
        .stencilTestEnable = c.vk.FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
    });

    const color_blend_attachment_state = std.mem.zeroInit(c.vk.PipelineColorBlendAttachmentState, .{
        .colorWriteMask = c.vk.COLOR_COMPONENT_R_BIT |
            c.vk.COLOR_COMPONENT_G_BIT |
            c.vk.COLOR_COMPONENT_B_BIT |
            c.vk.COLOR_COMPONENT_A_BIT,
    });

    const tri_mesh_vert_code align(4) = @embedFile("tri_mesh_vert").*;
    const tri_mesh_vert_module = create_shader_module(self, &tri_mesh_vert_code) orelse VK_NULL_HANDLE;
    defer c.vk.DestroyShaderModule(self.device, tri_mesh_vert_module, vk_alloc_cbs);
    if (tri_mesh_vert_module != VK_NULL_HANDLE) {
        log.info("Tri-mesh vert module loaded successfully", .{});
    }

    // Default lit shader
    const default_lit_frag_code align(4) = @embedFile("default_lit.frag").*;
    const default_lit_frag_module = create_shader_module(self, &default_lit_frag_code) orelse VK_NULL_HANDLE;
    defer c.vk.DestroyShaderModule(self.device, default_lit_frag_module, vk_alloc_cbs);
    if (default_lit_frag_module != VK_NULL_HANDLE) {
        log.info("Default lit frag module loaded successfully", .{});
    }

    const vert_stage_ci = std.mem.zeroInit(c.vk.PipelineShaderStageCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.vk.SHADER_STAGE_VERTEX_BIT,
        .module = tri_mesh_vert_module,
        .pName = "main",
    });

    const frag_stage_ci = std.mem.zeroInit(c.vk.PipelineShaderStageCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.vk.SHADER_STAGE_FRAGMENT_BIT,
        .module = default_lit_frag_module,
        .pName = "main",
    });

    var shader_stages = [_]c.vk.PipelineShaderStageCreateInfo{
        vert_stage_ci,
        frag_stage_ci,
    };

    var pipeline_builder = PipelineBuilder{
        .shader_stages = shader_stages[0..],
        .vertex_input_state = vertex_input_state_ci,
        .input_assembly_state = input_assembly_state_ci,
        .viewport = .{
            .x = 0.0,
            .y = 0.0,
            .width = @as(f32, @floatFromInt(self.swapchain_extent.width)),
            .height = @as(f32, @floatFromInt(self.swapchain_extent.height)),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        },
        .scissor = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        },
        .rasterization_state = rasterization_state_ci,
        .color_blend_attachment_state = color_blend_attachment_state,
        .multisample_state = multisample_state_ci,
        .pipeline_layout = undefined, // Will be set below
        .depth_stencil_state = depth_stencil_state_ci,
    };

    // New layout for push constants
    const push_constant_range = std.mem.zeroInit(c.vk.PushConstantRange, .{
        .stageFlags = c.vk.SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = @sizeOf(MeshPushConstants),
    });

    const set_layouts = [_]c.vk.DescriptorSetLayout{
        self.global_set_layout,
        self.object_set_layout,
    };

    const mesh_pipeline_layout_ci = std.mem.zeroInit(c.vk.PipelineLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = @as(u32, @intCast(set_layouts.len)),
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    });

    check_vk(c.vk.CreatePipelineLayout(self.device, &mesh_pipeline_layout_ci, vk_alloc_cbs, &self.mesh_pipeline_layout)) catch @panic("Failed to create mesh pipeline layout");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.mesh_pipeline_layout, c.vk.DestroyPipelineLayout),
    ) catch @panic("Out of memory");

    pipeline_builder.pipeline_layout = self.mesh_pipeline_layout;

    self.mesh_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.mesh_pipeline, c.vk.DestroyPipeline),
    ) catch @panic("Out of memory");
    if (self.mesh_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create mesh pipeline", .{});
    } else {
        log.info("Created mesh pipeline", .{});
    }

    // Create default material for Game of Life grid
    self.material = Material{
        .pipeline = self.mesh_pipeline,
        .pipeline_layout = self.mesh_pipeline_layout,
    };
}

fn init_descriptors(self: *Self) void {
    // Descriptor pool
    const pool_sizes = [_]c.vk.DescriptorPoolSize{
        .{
            .type = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 10,
        },
        .{
            .type = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .descriptorCount = 10,
        },
        .{
            .type = c.vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 10,
        },
        .{
            .type = c.vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 10,
        },
    };

    const pool_ci = std.mem.zeroInit(c.vk.DescriptorPoolCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = 0,
        .maxSets = 10,
        .poolSizeCount = @as(u32, @intCast(pool_sizes.len)),
        .pPoolSizes = &pool_sizes,
    });

    check_vk(c.vk.CreateDescriptorPool(self.device, &pool_ci, vk_alloc_cbs, &self.descriptor_pool)) catch @panic("Failed to create descriptor pool");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.descriptor_pool, c.vk.DestroyDescriptorPool),
    ) catch @panic("Out of memory");

    // =========================================================================
    // Information about the binding
    // =========================================================================

    // =================================
    // Global set layout
    //

    // Camera binding
    const camera_buffer_binding = std.mem.zeroInit(c.vk.DescriptorSetLayoutBinding, .{
        .binding = 0,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .descriptorCount = 1,
        .stageFlags = c.vk.SHADER_STAGE_VERTEX_BIT,
    });

    // Scene param binding
    const scene_parameters_binding = std.mem.zeroInit(c.vk.DescriptorSetLayoutBinding, .{
        .binding = 1,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .descriptorCount = 1,
        .stageFlags = c.vk.SHADER_STAGE_VERTEX_BIT | c.vk.SHADER_STAGE_FRAGMENT_BIT,
    });

    const bindings = [_]c.vk.DescriptorSetLayoutBinding{
        camera_buffer_binding,
        scene_parameters_binding,
    };

    const global_set_ci = std.mem.zeroInit(c.vk.DescriptorSetLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = @as(u32, @intCast(bindings.len)),
        .pBindings = &bindings,
    });

    check_vk(c.vk.CreateDescriptorSetLayout(self.device, &global_set_ci, vk_alloc_cbs, &self.global_set_layout)) catch @panic("Failed to create global descriptor set layout");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.global_set_layout, c.vk.DestroyDescriptorSetLayout),
    ) catch @panic("Out of memory");

    log.info("Created global set layout", .{});

    // =================================
    // Object set layout
    //

    // Object buffer binding
    const object_buffer_binding = std.mem.zeroInit(c.vk.DescriptorSetLayoutBinding, .{
        .binding = 0,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.vk.SHADER_STAGE_VERTEX_BIT,
    });

    const object_set_ci = std.mem.zeroInit(c.vk.DescriptorSetLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &object_buffer_binding,
    });

    check_vk(c.vk.CreateDescriptorSetLayout(self.device, &object_set_ci, vk_alloc_cbs, &self.object_set_layout)) catch @panic("Failed to create object descriptor set layout");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.object_set_layout, c.vk.DestroyDescriptorSetLayout),
    ) catch @panic("Out of memory");

    log.info("Created object set layout", .{});

    // Scene and camera (per-frame) in a single buffer
    // Only one buffer and we get multiple offset of of it
    const camera_and_scene_buffer_size =
        FRAME_OVERLAP * self.pad_uniform_buffer_size(@sizeOf(GPUCameraData)) +
        FRAME_OVERLAP * self.pad_uniform_buffer_size(@sizeOf(GPUSceneData));

    self.camera_and_scene_buffer = self.create_buffer(
        camera_and_scene_buffer_size,
        c.vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        c.vma.MEMORY_USAGE_CPU_TO_GPU,
    );
    self.buffer_deletion_queue.append(
        self.allocator,
        VmaBufferDeleter{ .buffer = self.camera_and_scene_buffer },
    ) catch @panic("Out of memory");

    // Camera and scene descriptor set
    const global_set_alloc_info = std.mem.zeroInit(c.vk.DescriptorSetAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.global_set_layout,
    });

    // Allocate a single set for multiple frame worth of camera and scene data
    check_vk(c.vk.AllocateDescriptorSets(self.device, &global_set_alloc_info, &self.camera_and_scene_set)) catch @panic("Failed to allocate global descriptor set");

    // Camera
    const camera_buffer_info = std.mem.zeroInit(c.vk.DescriptorBufferInfo, .{
        .buffer = self.camera_and_scene_buffer.buffer,
        .range = @sizeOf(GPUCameraData),
    });

    const camera_write = std.mem.zeroInit(c.vk.WriteDescriptorSet, .{
        .sType = c.vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self.camera_and_scene_set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .pBufferInfo = &camera_buffer_info,
    });

    // Scene parameters
    const scene_parameters_buffer_info = std.mem.zeroInit(c.vk.DescriptorBufferInfo, .{
        .buffer = self.camera_and_scene_buffer.buffer,
        .range = @sizeOf(GPUSceneData),
    });

    const scene_parameters_write = std.mem.zeroInit(c.vk.WriteDescriptorSet, .{
        .sType = c.vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self.camera_and_scene_set,
        .dstBinding = 1,
        .descriptorCount = 1,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .pBufferInfo = &scene_parameters_buffer_info,
    });

    const camera_and_scene_writes = [_]c.vk.WriteDescriptorSet{
        camera_write,
        scene_parameters_write,
    };

    c.vk.UpdateDescriptorSets(self.device, @as(u32, @intCast(camera_and_scene_writes.len)), &camera_and_scene_writes, 0, null);

    for (0..FRAME_OVERLAP) |i| {
        // ======================================================================
        // Allocate descriptor sets
        // ======================================================================

        // Object descriptor set
        const object_set_alloc_info = std.mem.zeroInit(c.vk.DescriptorSetAllocateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.object_set_layout,
        });

        check_vk(c.vk.AllocateDescriptorSets(self.device, &object_set_alloc_info, &self.frames[i].object_descriptor_set)) catch @panic("Failed to allocate object descriptor set");

        // ======================================================================
        // Buffer allocations
        // ======================================================================

        // Object buffer
        const MAX_OBJECTS = 10000;
        self.frames[i].object_buffer = self.create_buffer(
            MAX_OBJECTS * @sizeOf(GPUObjectData),
            c.vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.vma.MEMORY_USAGE_CPU_TO_GPU,
        );
        self.buffer_deletion_queue.append(
            self.allocator,
            VmaBufferDeleter{ .buffer = self.frames[i].object_buffer },
        ) catch @panic("Out of memory");

        // ======================================================================
        // Write descriptors
        // ======================================================================

        // =============================
        // Object descriptor set
        //
        const object_buffer_info = std.mem.zeroInit(c.vk.DescriptorBufferInfo, .{
            .buffer = self.frames[i].object_buffer.buffer,
            .offset = 0,
            .range = MAX_OBJECTS * @sizeOf(GPUObjectData),
        });

        const object_buffer_write = std.mem.zeroInit(c.vk.WriteDescriptorSet, .{
            .sType = c.vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self.frames[i].object_descriptor_set,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = c.vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &object_buffer_info,
        });

        const writes = [_]c.vk.WriteDescriptorSet{
            object_buffer_write,
        };

        c.vk.UpdateDescriptorSets(self.device, @as(u32, @intCast(writes.len)), &writes, 0, null);
    }
}

fn create_shader_module(self: *Self, code: []const u8) ?c.vk.ShaderModule {
    // NOTE: This being a better language than C/C++, means we don´t need to load
    // the SPIR-V code from a file, we can just embed it as an array of bytes.
    // To reflect the different behaviour from the original code, we also changed
    // the function name.
    std.debug.assert(code.len % 4 == 0);

    const data: *const u32 = @ptrCast(@alignCast(code.ptr));

    const shader_module_ci = std.mem.zeroInit(c.vk.ShaderModuleCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = data,
    });

    var shader_module: c.vk.ShaderModule = undefined;
    check_vk(c.vk.CreateShaderModule(self.device, &shader_module_ci, vk_alloc_cbs, &shader_module)) catch |err| {
        log.err("Failed to create shader module with error: {s}", .{@errorName(err)});
        return null;
    };

    return shader_module;
}

fn create_quad_mesh(allocator: std.mem.Allocator) Mesh {
    const vertices = allocator.alloc(Vertex, 6) catch @panic("OOM");

    // Two triangles forming a square (0,0 to 1,1)
    // Triangle 1
    vertices[0] = Vertex{
        .position = Vec3.make(0.0, 0.0, 0.0),
        .normal = Vec3.make(0.0, 0.0, 1.0),
        .color = Vec3.make(1.0, 1.0, 1.0), // White
        .uv = Vec2.make(0.0, 0.0),
    };
    vertices[1] = Vertex{
        .position = Vec3.make(1.0, 0.0, 0.0),
        .normal = Vec3.make(0.0, 0.0, 1.0),
        .color = Vec3.make(1.0, 1.0, 1.0),
        .uv = Vec2.make(1.0, 0.0),
    };
    vertices[2] = Vertex{
        .position = Vec3.make(1.0, 1.0, 0.0),
        .normal = Vec3.make(0.0, 0.0, 1.0),
        .color = Vec3.make(1.0, 1.0, 1.0),
        .uv = Vec2.make(1.0, 1.0),
    };

    // Triangle 2
    vertices[3] = Vertex{
        .position = Vec3.make(0.0, 0.0, 0.0),
        .normal = Vec3.make(0.0, 0.0, 1.0),
        .color = Vec3.make(1.0, 1.0, 1.0),
        .uv = Vec2.make(0.0, 0.0),
    };
    vertices[4] = Vertex{
        .position = Vec3.make(1.0, 1.0, 0.0),
        .normal = Vec3.make(0.0, 0.0, 1.0),
        .color = Vec3.make(1.0, 1.0, 1.0),
        .uv = Vec2.make(1.0, 1.0),
    };
    vertices[5] = Vertex{
        .position = Vec3.make(0.0, 1.0, 0.0),
        .normal = Vec3.make(0.0, 0.0, 1.0),
        .color = Vec3.make(1.0, 1.0, 1.0),
        .uv = Vec2.make(0.0, 1.0),
    };

    return Mesh{ .vertices = vertices };
}

fn load_meshes(self: *Self) void {
    // Create quad mesh
    self.quad_mesh = create_quad_mesh(self.allocator);
    self.upload_mesh(&self.quad_mesh);
}

fn upload_mesh(self: *Self, mesh: *Mesh) void {
    // Upload quad mesh to GPU
    const buffer_size = mesh.vertices.len * @sizeOf(Vertex);

    // Create staging buffer
    const staging_buffer = self.create_buffer(
        buffer_size,
        c.vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        c.vma.MEMORY_USAGE_CPU_ONLY,
    );
    defer c.vma.DestroyBuffer(self.vma_allocator, staging_buffer.buffer, staging_buffer.allocation);
    log.info("Created staging buffer {}", .{@intFromPtr(staging_buffer.buffer)});

    // Copy vertex data to staging buffer
    var data: ?*anyopaque = undefined;
    check_vk(c.vma.MapMemory(self.vma_allocator, staging_buffer.allocation, &data)) catch @panic("Failed to map staging buffer");
    const dest: [*]Vertex = @ptrCast(@alignCast(data));
    @memcpy(dest[0..mesh.vertices.len], mesh.vertices);
    c.vma.UnmapMemory(self.vma_allocator, staging_buffer.allocation);
    log.info("Copied mesh data into staging buffer", .{});

    // Create vertex buffer on GPU
    mesh.vertex_buffer = self.create_buffer(
        buffer_size,
        c.vk.BUFFER_USAGE_VERTEX_BUFFER_BIT | c.vk.BUFFER_USAGE_TRANSFER_DST_BIT,
        c.vma.MEMORY_USAGE_GPU_ONLY,
    );
    log.info("Created GPU buffer for mesh {}", .{@intFromPtr(mesh.vertex_buffer.buffer)});

    // Track for cleanup
    self.buffer_deletion_queue.append(
        self.allocator,
        VmaBufferDeleter{ .buffer = mesh.vertex_buffer },
    ) catch @panic("Out of memory");

    // Now we can copy immediate the content of the staging buffer to the gpu only memory.
    self.immediate_submit(struct {
        mesh_buffer: c.vk.Buffer,
        staging_buffer: c.vk.Buffer,
        size: usize,

        fn submit(ctx: @This(), cmd: c.vk.CommandBuffer) void {
            const copy_region = std.mem.zeroInit(c.vk.BufferCopy, .{
                .size = ctx.size,
            });
            c.vk.CmdCopyBuffer(cmd, ctx.staging_buffer, ctx.mesh_buffer, 1, &copy_region);
        }
    }{
        .mesh_buffer = mesh.vertex_buffer.buffer,
        .staging_buffer = staging_buffer.buffer,
        .size = buffer_size,
    });

    log.info("Uploaded quad mesh ({} vertices), vertex_buffer={any}", .{ mesh.vertices.len, mesh.vertex_buffer.buffer });
}

fn init_gui(self: *Self) void {
    // how many frames in flight we want
    // NOTE: swapchain image count = prefered_frames_in_flight + 1 (because 1 is being presented and not worked on)
    // const prefered_frames_in_flight = 2;
    // just in case we don't get `prefered_frames_in_flight` as fallback
    // max frames in flight app can support (in case device requires more than preferred)
    const max_frames_in_flight = 3;

    // create SDL backend using existing window and renderer, app still owns the window/renderer
    const dvui_backend_ptr = self.allocator.create(DvuiBackend) catch @panic("Failed to allocate DvuiBackend");
    dvui_backend_ptr.* = DvuiBackend.init(
        self.allocator,
        self.sdl_window,
        .{
            .dev = self.device,
            .queue = self.graphics_queue, // or should it be self.present_queue
            .command_pool = self.upload_context.command_pool,
            .pdev = self.physical_device,
            .render_pass = self.render_pass,
            .vk_alloc = vk_alloc_cbs,

            .max_frames_in_flight = max_frames_in_flight,

            // tight limits
            .max_indices_per_frame = 1024 * 96,
            .max_vertices_per_frame = 1024 * 32,

            // test overflow
            // .max_indices_per_frame = 1024 * 32,
            // .max_vertices_per_frame = 1024 * 16,
        },
    );

    // init dvui Window (maps onto a single OS window)
    self.dvui_window = dvui.Window.init(@src(), self.allocator, dvui_backend_ptr.backend(), .{}) catch @panic("Failed to create DVUI window");
    self.dvui_window.?.theme = dvui.Theme.builtin.adwaita_dark;

    dvui.Examples.show_demo_window = true;
}

// caller is responsible for checking that self.dvui_window is non-null
fn dvui_backend(self: *const Self) *DvuiBackend {
    return self.dvui_window.?.backend.impl;
}

pub fn cleanup(self: *Self) void {
    check_vk(c.vk.DeviceWaitIdle(self.device)) catch @panic("Failed to wait for device idle");

    if (self.dvui_window) |*dvui_window| {
        const dvui_backend_ptr = self.dvui_backend();
        dvui_window.deinit();
        dvui_backend_ptr.deinit();
        self.allocator.destroy(dvui_backend_ptr);
    }

    self.allocator.free(self.quad_mesh.vertices);

    for (self.buffer_deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.buffer_deletion_queue.deinit(self.allocator);

    for (self.image_deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.image_deletion_queue.deinit(self.allocator);

    for (self.deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.deletion_queue.deinit(self.allocator);

    self.present_semaphores.deinit(self.allocator);

    self.allocator.free(self.framebuffers);
    self.allocator.free(self.swapchain_image_views);
    self.allocator.free(self.swapchain_images);

    c.vma.DestroyAllocator(self.vma_allocator);

    c.vk.DestroyDevice(self.device, vk_alloc_cbs);
    c.vk.DestroySurfaceKHR(self.instance, self.surface, vk_alloc_cbs);

    if (self.debug_messenger != VK_NULL_HANDLE) {
        const destroy_fn = vki.get_destroy_debug_utils_messenger_fn(self.instance).?;
        destroy_fn(self.instance, self.debug_messenger, vk_alloc_cbs);
    }

    c.vk.DestroyInstance(self.instance, vk_alloc_cbs);
    c.SDL.DestroyWindow(self.sdl_window);
    c.SDL.Quit();
}

// fn gui_stats(vk_backend: *const DvuiBackend.DvuiVkRenderer) !void {
//     const stats = vk_backend.stats;

//     var m = dvui.box(@src(), .{}, .{
//         .background = true,
//         .expand = null,
//         .gravity_x = 1.0,
//         .min_size_content = .{ .w = 300, .h = 0 },
//     });
//     defer m.deinit();
//     var prc: f32 = 0; // progress bar percent [0..1]

//     dvui.labelNoFmt(@src(), "DVUI VK Backend stats", .{}, .{
//         .expand = .horizontal,
//         .gravity_x = 0.5,
//         .font_style = .heading,
//     });
//     dvui.label(@src(), "draw_calls:  {}", .{stats.draw_calls}, .{ .expand = .horizontal });

//     const idx_max = vk_backend.current_frame.idx_data.len / @sizeOf(DvuiBackend.DvuiVkRenderer.Indice);
//     dvui.label(@src(), "indices: {} / {}", .{ stats.indices, idx_max }, .{ .expand = .horizontal });
//     prc = @as(f32, @floatFromInt(stats.indices)) / @as(f32, @floatFromInt(idx_max));
//     dvui.progress(@src(), .{ .percent = prc }, .{
//         .expand = .horizontal,
//         .color_fill = dvui.Color.fromHSLuv(@max(12, (1 - prc * prc) * 155), 99, 50, 100),
//     });

//     const verts_max = vk_backend.current_frame.vtx_data.len / @sizeOf(DvuiBackend.DvuiVkRenderer.Vertex);
//     dvui.label(@src(), "vertices:  {} / {}", .{ stats.verts, verts_max }, .{ .expand = .horizontal });
//     prc = @as(f32, @floatFromInt(stats.verts)) / @as(f32, @floatFromInt(verts_max));
//     dvui.progress(@src(), .{ .percent = prc }, .{
//         .expand = .horizontal,
//         .color_fill = dvui.Color.fromHSLuv(@max(12, (1 - prc * prc) * 155), 99, 50, 100),
//     });

//     dvui.label(@src(), "Textures:", .{}, .{ .expand = .horizontal, .font_style = .caption_heading });
//     dvui.label(@src(), "count:  {}", .{stats.textures_alive}, .{ .expand = .horizontal });
//     dvui.label(@src(), "mem (gpu): {Bi:.1}", .{stats.textures_mem}, .{ .expand = .horizontal });

//     dvui.label(@src(), "Static/Preallocated memory (gpu):", .{}, .{ .expand = .horizontal, .font_style = .caption_heading });
//     const prealloc_mem = vk_backend.host_vis_data.len;
//     dvui.label(@src(), "total:  {Bi:.1}", .{prealloc_mem}, .{ .expand = .horizontal });
//     const prealloc_mem_frame = prealloc_mem / vk_backend.frames.len;
//     const prealloc_mem_frame_used = stats.indices * @sizeOf(DvuiBackend.DvuiVkRenderer.Indice) +
//         stats.verts * @sizeOf(DvuiBackend.DvuiVkRenderer.Vertex);
//     dvui.label(
//         @src(),
//         "current frame:  {Bi:.1} / {Bi:.1}",
//         .{ prealloc_mem_frame_used, prealloc_mem_frame },
//         .{ .expand = .horizontal },
//     );
//     prc = @as(f32, @floatFromInt(prealloc_mem_frame_used)) / @as(f32, @floatFromInt(prealloc_mem_frame));
//     dvui.progress(@src(), .{ .percent = prc }, .{
//         .expand = .horizontal,
//         .color_fill = dvui.Color.fromHSLuv(@max(12, (1 - prc * prc) * 155), 99, 50, 100),
//     });
// }

pub fn run(self: *Self) void {
    // static counter
    const TitleDelay = struct {
        var accumulator: f32 = 0.0;
    };

    var timer = std.time.Timer.start() catch @panic("Failed to start timer");
    var delta: f32 = 0.016;

    var quit = false;
    var event: c.SDL.Event = undefined;
    while (!quit) {
        while (c.SDL.PollEvent(&event) != false) {
            if (event.type == c.SDL.EVENT_QUIT) {
                quit = true;
            } else if (self.dvui_window != null and addEvent(&self.dvui_window.?, event) catch false) {
                // Nothing to do here
            } else if (event.type == c.SDL.EVENT_KEY_DOWN) {
                log.debug("unhandled keyboard press", .{});
            }
        }

        // run app logic
        self.app.run_app(c.SDL.GetTicks());

        self.draw();
        self.frame_number +%= 1;

        delta = @floatCast(@as(f64, @floatFromInt(timer.lap())) / 1_000_000_000.0);
        TitleDelay.accumulator += delta;
        if (TitleDelay.accumulator > 0.1) {
            TitleDelay.accumulator = 0.0;
            const fps = 1.0 / delta;
            const new_title = std.fmt.allocPrintSentinel(
                self.allocator,
                "Vulkan - FPS: {d:6.3}, ms: {d:6.3}",
                .{ fps, delta * 1000.0 },
                0,
            ) catch @panic("Out of memory");
            defer self.allocator.free(new_title);
            _ = c.SDL.SetWindowTitle(self.sdl_window, new_title.ptr);
        }
    }
}

fn get_current_frame(self: *Self) FrameData {
    return self.frames[@intCast(@mod(self.frame_number, FRAME_OVERLAP))];
}

fn draw(self: *Self) void {
    // Wait until the GPU has finished rendering the last frame
    const timeout: u64 = 1_000_000_000; // 1 second in nanonesconds
    const frame = self.get_current_frame();

    check_vk(c.vk.WaitForFences(self.device, 1, &frame.render_fence, c.vk.TRUE, timeout)) catch @panic("Failed to wait for render fence");
    check_vk(c.vk.ResetFences(self.device, 1, &frame.render_fence)) catch @panic("Failed to reset render fence");

    var swapchain_image_index: u32 = undefined;
    check_vk(c.vk.AcquireNextImageKHR(
        self.device,
        self.swapchain,
        timeout,
        frame.swapchain_semaphore,
        VK_NULL_HANDLE,
        &swapchain_image_index,
    )) catch |e| {
        std.log.err("Error: {s}", .{@errorName(e)});
        @panic("Failed to acquire swapchain image");
    };

    var cmd = frame.main_command_buffer;

    check_vk(c.vk.ResetCommandBuffer(cmd, 0)) catch @panic("Failed to reset command buffer");

    const cmd_begin_info = std.mem.zeroInit(c.vk.CommandBufferBeginInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });

    check_vk(c.vk.BeginCommandBuffer(cmd, &cmd_begin_info)) catch @panic("Failed to begin command buffer");

    // Make a claer color that changes with each frame (120*pi frame period)
    // Set clear color to black for Game of Life grid background
    const color_clear: c.vk.ClearValue = .{
        .color = .{ .float32 = [_]f32{ 0.0, 0.0, 0.0, 1.0 } },
    };

    const depth_clear = c.vk.ClearValue{
        .depthStencil = .{
            .depth = 1.0,
            .stencil = 0,
        },
    };

    const clear_values = [_]c.vk.ClearValue{
        color_clear,
        depth_clear,
    };

    const render_pass_begin_info = std.mem.zeroInit(c.vk.RenderPassBeginInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = self.render_pass,
        .framebuffer = self.framebuffers[swapchain_image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        },
        .clearValueCount = @as(u32, @intCast(clear_values.len)),
        .pClearValues = &clear_values,
    });
    c.vk.CmdBeginRenderPass(cmd, &render_pass_begin_info, c.vk.SUBPASS_CONTENTS_INLINE);

    // Store current command buffer for app to use
    self.current_cmd = cmd;

    // Update app render state and draw objects
    self.app.draw_contents(self);

    // gui
    if (self.dvui_window) |*win| {
        // log.debug("swapchain_extent={} win_size_in_pixels={}", .{self.swapchain_extent, backend.windowSizeInPixels()});
        self.dvui_backend().renderer.beginFrame(cmd, self.swapchain_extent);

        // beginWait coordinates with waitTime (?) below to run frames only when needed
        _ = win.beginWait(false);

        win.begin(std.time.nanoTimestamp()) catch @panic("window.begin() failed");
        self.app.draw_ui(win);
        _ = win.end(.{}) catch @panic("win.end() failed");

        _ = self.dvui_backend().renderer.endFrame();
    } else {
        c.vk.CmdEndRenderPass(cmd);
    }

    check_vk(c.vk.EndCommandBuffer(cmd)) catch @panic("Failed to end command buffer");

    const wait_stage = @as(u32, @intCast(c.vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT));
    const submit_info = std.mem.zeroInit(c.vk.SubmitInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &frame.swapchain_semaphore,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &self.present_semaphores.items[swapchain_image_index],
    });
    check_vk(c.vk.QueueSubmit(self.graphics_queue, 1, &submit_info, frame.render_fence)) catch @panic("Failed to submit to graphics queue");

    const present_info = std.mem.zeroInit(c.vk.PresentInfoKHR, .{
        .sType = c.vk.STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &self.present_semaphores.items[swapchain_image_index],
        .swapchainCount = 1,
        .pSwapchains = &self.swapchain,
        .pImageIndices = &swapchain_image_index,
    });
    check_vk(c.vk.QueuePresentKHR(self.present_queue, &present_info)) catch @panic("Failed to present swapchain image");
}

pub fn draw_objects(self: *Self, objects: []RenderObject) void {
    const cmd = self.current_cmd;
    if (cmd == VK_NULL_HANDLE) {
        log.warn("draw_objects called outside of draw context", .{});
        return;
    }
    if (objects.len == 0) {
        log.info("draw_objects called with 0 objects", .{});
        return;
    }

    // log.debug("draw_objects: rendering {} objects", .{objects.len});

    // Use orthographic projection for 2D grid rendering
    // This creates a coordinate system where (0,0) is top-left
    // Grid is 128x72, so we use those dimensions plus some margin
    const grid_width: f32 = 130.0; // Slightly larger than 128
    const grid_height: f32 = 75.0; // Slightly larger than 72
    // For Vulkan with top-left origin: left, right, bottom, top
    // We want Y to increase downward, so bottom=0, top=grid_height
    const proj = Mat4.orthographic(0.0, grid_width, 0.0, grid_height, -1.0, 1.0);

    const frame_index: usize = @intCast(@mod(self.frame_number, FRAME_OVERLAP));

    // TODO: meta function that deals with alignment and copying of data with
    // map/unmap. We now have two versions, one for a single pointer to struct
    // and one for array/slices (used to copy mesh vertices).
    const padded_camera_data_size = self.pad_uniform_buffer_size(@sizeOf(GPUCameraData));
    const scene_data_base_offset = padded_camera_data_size * FRAME_OVERLAP;
    const padded_scene_data_size = self.pad_uniform_buffer_size(@sizeOf(GPUSceneData));

    const camera_data_offset = padded_camera_data_size * frame_index;
    const scene_data_offset = scene_data_base_offset + padded_scene_data_size * frame_index;

    var data: ?*anyopaque = undefined;
    check_vk(c.vma.MapMemory(self.vma_allocator, self.camera_and_scene_buffer.allocation, &data)) catch @panic("Failed to map camera buffer");

    // Update camera data with orthographic projection and identity view
    const camera_data: *GPUCameraData = @ptrFromInt(@intFromPtr(data) + camera_data_offset);
    camera_data.view = Mat4.IDENTITY; // Identity view for 2D rendering
    camera_data.proj = proj;
    camera_data.view_proj = proj; // Since view is identity, view_proj = proj

    const scene_data: *GPUSceneData = @ptrFromInt(@intFromPtr(data) + scene_data_offset);
    // Set ambient color to black for black background
    scene_data.ambient_color = Vec3.make(0.0, 0.0, 0.0).to_point4();

    c.vma.UnmapMemory(self.vma_allocator, self.camera_and_scene_buffer.allocation);

    // NOTE: In this copy I do conversion. Now, this is generally unsafe as none
    // of the structures involved are c compatible (marked extern). However, we
    // so happen to know it is safe to do so for Mat4.
    // TODO: In the future we should mark all the math structure as extern, so
    // we can more easily pass them back and forth from C and do those kind of
    // conversions.
    var object_data: ?*anyopaque = undefined;
    check_vk(c.vma.MapMemory(self.vma_allocator, self.get_current_frame().object_buffer.allocation, &object_data)) catch @panic("Failed to map object buffer");
    var object_data_arr: [*]GPUObjectData = @ptrCast(@alignCast(object_data orelse unreachable));
    for (objects, 0..) |object, index| {
        object_data_arr[index] = GPUObjectData{
            .model_matrix = object.transform,
        };
    }
    c.vma.UnmapMemory(self.vma_allocator, self.get_current_frame().object_buffer.allocation);

    for (objects, 0..) |object, index| {
        // if (index == 0) {
        //     log.debug(
        //         "First object: mesh={*}, material.pipeline={any}, vertices={}",
        //         .{ object.mesh, object.material.pipeline, object.mesh.vertices.len },
        //     );
        //     log.debug(
        //         "First object transform.t (position): x={d:.2}, y={d:.2}, z={d:.2}, w={d:.2}",
        //         .{ object.transform.t.x, object.transform.t.y, object.transform.t.z, object.transform.t.w },
        //     );
        // }

        if (index == 0 or object.material != objects[index - 1].material) {
            c.vk.CmdBindPipeline(cmd, c.vk.PIPELINE_BIND_POINT_GRAPHICS, object.material.pipeline);

            // Compute the offset for dynamic uniform buffers (for now just the one containing scene data, the
            // camera data is not dynamic)
            const uniform_offsets = [_]u32{
                @as(u32, @intCast(camera_data_offset)),
                @as(u32, @intCast(scene_data_offset)),
            };

            c.vk.CmdBindDescriptorSets(
                cmd,
                c.vk.PIPELINE_BIND_POINT_GRAPHICS,
                object.material.pipeline_layout,
                0,
                1,
                &self.camera_and_scene_set,
                @as(u32, @intCast(uniform_offsets.len)),
                &uniform_offsets,
            );

            c.vk.CmdBindDescriptorSets(
                cmd,
                c.vk.PIPELINE_BIND_POINT_GRAPHICS,
                object.material.pipeline_layout,
                1,
                1,
                &self.get_current_frame().object_descriptor_set,
                0,
                null,
            );
        }

        if (object.material.texture_set != VK_NULL_HANDLE) {
            c.vk.CmdBindDescriptorSets(
                cmd,
                c.vk.PIPELINE_BIND_POINT_GRAPHICS,
                object.material.pipeline_layout,
                2,
                1,
                &object.material.texture_set,
                0,
                null,
            );
        }

        const push_constants = MeshPushConstants{
            .data = Vec4.ZERO,
            .render_matrix = object.transform,
        };

        c.vk.CmdPushConstants(
            cmd,
            object.material.pipeline_layout,
            c.vk.SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(MeshPushConstants),
            &push_constants,
        );

        if (index == 0 or object.mesh != objects[index - 1].mesh) {
            const offset: c.vk.DeviceSize = 0;
            c.vk.CmdBindVertexBuffers(cmd, 0, 1, &object.mesh.vertex_buffer.buffer, &offset);
        }

        // if (index == 0) {
        //     log.debug("About to call CmdDraw with {} vertices, instance={}", .{ object.mesh.vertices.len, index });
        // }

        c.vk.CmdDraw(cmd, @as(u32, @intCast(object.mesh.vertices.len)), 1, 0, @intCast(index));
    }
}

pub fn create_buffer(self: *Self, alloc_size: usize, usage: c.vk.BufferUsageFlags, memory_usage: c.vma.MemoryUsage) AllocatedBuffer {
    const buffer_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = alloc_size,
        .usage = usage,
    });

    const vma_alloc_info = std.mem.zeroInit(c.vma.AllocationCreateInfo, .{
        .usage = memory_usage,
    });

    var buffer: AllocatedBuffer = undefined;
    check_vk(c.vma.CreateBuffer(
        self.vma_allocator,
        &buffer_ci,
        &vma_alloc_info,
        &buffer.buffer,
        &buffer.allocation,
        null,
    )) catch @panic("Failed to create buffer");

    return buffer;
}

fn pad_uniform_buffer_size(self: *Self, original_size: usize) usize {
    const min_ubo_alignment = @as(usize, @intCast(self.physical_device_properties.limits.minUniformBufferOffsetAlignment));
    const aligned_size = (original_size + min_ubo_alignment - 1) & ~(min_ubo_alignment - 1);
    return aligned_size;
}

pub fn immediate_submit(self: *Self, submit_ctx: anytype) void {
    // Check the context is good
    comptime {
        var Context = @TypeOf(submit_ctx);
        var is_ptr = false;
        switch (@typeInfo(Context)) {
            .@"struct", .@"union", .@"enum" => {},
            .pointer => |ptr| {
                if (ptr.size != .one) {
                    @compileError("Context must be a type with a submit function. " ++ @typeName(Context) ++ "is a multi element pointer");
                }
                Context = ptr.child;
                is_ptr = true;
                switch (Context) {
                    .Struct, .Union, .Enum, .Opaque => {},
                    else => @compileError("Context must be a type with a submit function. " ++ @typeName(Context) ++ "is a pointer to a non struct/union/enum/opaque type"),
                }
            },
            else => @compileError("Context must be a type with a submit method. Cannot use: " ++ @typeName(Context)),
        }

        if (!@hasDecl(Context, "submit")) {
            @compileError("Context should have a submit method");
        }

        const submit_fn_info = @typeInfo(@TypeOf(Context.submit));
        if (submit_fn_info != .@"fn") {
            @compileError("Context submit method should be a function");
        }

        if (submit_fn_info.@"fn".params.len != 2) {
            @compileError("Context submit method should have two parameters");
        }

        if (submit_fn_info.@"fn".params[0].type != Context) {
            @compileError("Context submit method first parameter should be of type: " ++ @typeName(Context));
        }

        if (submit_fn_info.@"fn".params[1].type != c.vk.CommandBuffer) {
            @compileError("Context submit method second parameter should be of type: " ++ @typeName(c.vk.CommandBuffer));
        }
    }

    const cmd = self.upload_context.command_buffer;

    const commmand_begin_ci = std.mem.zeroInit(c.vk.CommandBufferBeginInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    check_vk(c.vk.BeginCommandBuffer(cmd, &commmand_begin_ci)) catch @panic("Failed to begin command buffer");

    submit_ctx.submit(cmd);

    check_vk(c.vk.EndCommandBuffer(cmd)) catch @panic("Failed to end command buffer");

    const submit_info = std.mem.zeroInit(c.vk.SubmitInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    });

    check_vk(c.vk.QueueSubmit(self.graphics_queue, 1, &submit_info, self.upload_context.upload_fence)) catch @panic("Failed to submit to graphics queue");

    check_vk(c.vk.WaitForFences(self.device, 1, &self.upload_context.upload_fence, c.vk.TRUE, 1_000_000_000)) catch @panic("Failed to wait for upload fence");
    check_vk(c.vk.ResetFences(self.device, 1, &self.upload_context.upload_fence)) catch @panic("Failed to reset upload fence");

    check_vk(c.vk.ResetCommandPool(self.device, self.upload_context.command_pool, 0)) catch @panic("Failed to reset command pool");
}

//
// input handling
//

const log_input_events = false;

fn addEvent(win: *dvui.Window, event: c.SDL.Event) !bool {
    switch (event.type) {
        c.SDL.EVENT_KEY_DOWN => {
            const sdl_scancode: c.SDL.Scancode = event.key.scancode;
            const code = SDL_scancode_to_dvui(sdl_scancode);
            const mod = SDL_keymod_to_dvui(event.key.mod);
            if (log_input_events) {
                log.debug("event KEYDOWN {any} {s} {any} {any}\n", .{ sdl_scancode, @tagName(code), mod, event.key.repeat });
            }

            return try win.addEventKey(.{
                .code = code,
                .action = if (event.key.repeat) .repeat else .down,
                .mod = mod,
            });
        },
        c.SDL.EVENT_KEY_UP => {
            const sdl_scancode: c.SDL.Scancode = event.key.scancode;
            const code = SDL_scancode_to_dvui(sdl_scancode);
            const mod = SDL_keymod_to_dvui(event.key.mod);
            if (log_input_events) {
                log.debug("event KEYUP {any} {s} {any}\n", .{ sdl_scancode, @tagName(code), mod });
            }

            return try win.addEventKey(.{
                .code = code,
                .action = .up,
                .mod = mod,
            });
        },
        c.SDL.EVENT_TEXT_INPUT => {
            const txt = std.mem.sliceTo(event.text.text, 0);
            if (log_input_events) {
                log.debug("event TEXTINPUT {s}\n", .{txt});
            }

            return try win.addEventText(.{ .text = txt });
        },
        c.SDL.EVENT_TEXT_EDITING => {
            const strlen: u8 = @intCast(c.SDL.strlen(event.edit.text));
            if (log_input_events) {
                log.debug("event TEXTEDITING {s} start {d} len {d} strlen {d}\n", .{ event.edit.text, event.edit.start, event.edit.length, strlen });
            }
            return try win.addEventText(.{ .text = event.edit.text[0..strlen], .selected = true });
        },
        c.SDL.EVENT_MOUSE_MOTION => {
            // sdl gives us mouse coords in "window coords" which is kind of
            // like natural coords but ignores content scaling
            const pixel_size = win.backend.pixelSize();
            const window_size = win.backend.windowSize();
            const scale_x = pixel_size.w / window_size.w;
            const scale_y = pixel_size.h / window_size.h;

            if (log_input_events) {
                const touch = event.motion.which == c.SDL.TOUCH_MOUSEID;
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                log.debug("event{s}MOUSEMOTION {d} {d} {} {}\n", .{ touch_str, event.motion.x, event.motion.y, scale_x, scale_y });
            }

            return try win.addEventMouseMotion(.{
                .pt = .{
                    .x = event.motion.x * scale_x,
                    .y = event.motion.y * scale_y,
                },
            });
        },
        c.SDL.EVENT_MOUSE_BUTTON_DOWN => {
            if (log_input_events) {
                const touch = event.motion.which == c.SDL.TOUCH_MOUSEID;
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                log.debug("event{s}MOUSEBUTTONDOWN {d}\n", .{ touch_str, event.button.button });
            }

            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .press);
        },
        c.SDL.EVENT_MOUSE_BUTTON_UP => {
            if (log_input_events) {
                const touch = event.motion.which == c.SDL.TOUCH_MOUSEID;
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                log.debug("event{s}MOUSEBUTTONUP {d}\n", .{ touch_str, event.button.button });
            }

            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .release);
        },
        c.SDL.EVENT_MOUSE_WHEEL => {
            // .precise added in 2.0.18
            const ticks_x = event.wheel.x;
            const ticks_y = event.wheel.y;

            if (log_input_events) {
                log.debug("event MOUSEWHEEL {d} {d} {d}\n", .{ ticks_x, ticks_y, event.wheel.which });
            }

            var ret = false;
            if (ticks_x != 0) ret = try win.addEventMouseWheel(ticks_x * dvui.scroll_speed, .horizontal);
            if (ticks_y != 0) ret = try win.addEventMouseWheel(ticks_y * dvui.scroll_speed, .vertical);
            return ret;
        },
        c.SDL.EVENT_FINGER_DOWN => {
            if (log_input_events) {
                log.debug("event FINGERDOWN {d} {d} {d}\n", .{ event.tfinger.fingerID, event.tfinger.x, event.tfinger.y });
            }

            return try win.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = event.tfinger.x, .y = event.tfinger.y } });
        },
        c.SDL.EVENT_FINGER_UP => {
            if (log_input_events) {
                log.debug("event FINGERUP {d} {d} {d}\n", .{ event.tfinger.fingerID, event.tfinger.x, event.tfinger.y });
            }

            return try win.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = event.tfinger.x, .y = event.tfinger.y } });
        },
        c.SDL.EVENT_FINGER_MOTION => {
            if (log_input_events) {
                log.debug("event FINGERMOTION {d} {d} {d} {d} {d}\n", .{ event.tfinger.fingerID, event.tfinger.x, event.tfinger.y, event.tfinger.dx, event.tfinger.dy });
            }

            return try win.addEventTouchMotion(.touch0, event.tfinger.x, event.tfinger.y, event.tfinger.dx, event.tfinger.dy);
        },
        else => {
            if (log_input_events) {
                log.debug("unhandled SDL event type {any}\n", .{event.type});
            }
            return false;
        },
    }
}

fn SDL_mouse_button_to_dvui(button: u8) dvui.enums.Button {
    return switch (button) {
        c.SDL.BUTTON_LEFT => .left,
        c.SDL.BUTTON_MIDDLE => .middle,
        c.SDL.BUTTON_RIGHT => .right,
        c.SDL.BUTTON_X1 => .four,
        c.SDL.BUTTON_X2 => .five,
        else => blk: {
            log.debug("SDL_mouse_button_to_dvui.unknown button {d}", .{button});
            break :blk .six;
        },
    };
}

fn SDL_keymod_to_dvui(keymod: c.SDL.Keymod) dvui.enums.Mod {
    if (keymod == c.SDL.KMOD_NONE) return dvui.enums.Mod.none;

    var m: u16 = 0;
    if ((keymod & c.SDL.KMOD_LSHIFT) > 0) m |= @intFromEnum(dvui.enums.Mod.lshift);
    if ((keymod & c.SDL.KMOD_RSHIFT) > 0) m |= @intFromEnum(dvui.enums.Mod.rshift);
    if ((keymod & c.SDL.KMOD_LCTRL) > 0) m |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if ((keymod & c.SDL.KMOD_RCTRL) > 0) m |= @intFromEnum(dvui.enums.Mod.rcontrol);
    if ((keymod & c.SDL.KMOD_LALT) > 0) m |= @intFromEnum(dvui.enums.Mod.lalt);
    if ((keymod & c.SDL.KMOD_RALT) > 0) m |= @intFromEnum(dvui.enums.Mod.ralt);
    if ((keymod & c.SDL.KMOD_LGUI) > 0) m |= @intFromEnum(dvui.enums.Mod.lcommand);
    if ((keymod & c.SDL.KMOD_RGUI) > 0) m |= @intFromEnum(dvui.enums.Mod.rcommand);

    return @as(dvui.enums.Mod, @enumFromInt(m));
}

fn SDL_scancode_to_dvui(scancode: c.SDL.Scancode) dvui.enums.Key {
    return switch (scancode) {
        c.SDL.SCANCODE_A => .a,
        c.SDL.SCANCODE_B => .b,
        c.SDL.SCANCODE_C => .c,
        c.SDL.SCANCODE_D => .d,
        c.SDL.SCANCODE_E => .e,
        c.SDL.SCANCODE_F => .f,
        c.SDL.SCANCODE_G => .g,
        c.SDL.SCANCODE_H => .h,
        c.SDL.SCANCODE_I => .i,
        c.SDL.SCANCODE_J => .j,
        c.SDL.SCANCODE_K => .k,
        c.SDL.SCANCODE_L => .l,
        c.SDL.SCANCODE_M => .m,
        c.SDL.SCANCODE_N => .n,
        c.SDL.SCANCODE_O => .o,
        c.SDL.SCANCODE_P => .p,
        c.SDL.SCANCODE_Q => .q,
        c.SDL.SCANCODE_R => .r,
        c.SDL.SCANCODE_S => .s,
        c.SDL.SCANCODE_T => .t,
        c.SDL.SCANCODE_U => .u,
        c.SDL.SCANCODE_V => .v,
        c.SDL.SCANCODE_W => .w,
        c.SDL.SCANCODE_X => .x,
        c.SDL.SCANCODE_Y => .y,
        c.SDL.SCANCODE_Z => .z,

        c.SDL.SCANCODE_0 => .zero,
        c.SDL.SCANCODE_1 => .one,
        c.SDL.SCANCODE_2 => .two,
        c.SDL.SCANCODE_3 => .three,
        c.SDL.SCANCODE_4 => .four,
        c.SDL.SCANCODE_5 => .five,
        c.SDL.SCANCODE_6 => .six,
        c.SDL.SCANCODE_7 => .seven,
        c.SDL.SCANCODE_8 => .eight,
        c.SDL.SCANCODE_9 => .nine,

        c.SDL.SCANCODE_F1 => .f1,
        c.SDL.SCANCODE_F2 => .f2,
        c.SDL.SCANCODE_F3 => .f3,
        c.SDL.SCANCODE_F4 => .f4,
        c.SDL.SCANCODE_F5 => .f5,
        c.SDL.SCANCODE_F6 => .f6,
        c.SDL.SCANCODE_F7 => .f7,
        c.SDL.SCANCODE_F8 => .f8,
        c.SDL.SCANCODE_F9 => .f9,
        c.SDL.SCANCODE_F10 => .f10,
        c.SDL.SCANCODE_F11 => .f11,
        c.SDL.SCANCODE_F12 => .f12,

        c.SDL.SCANCODE_KP_DIVIDE => .kp_divide,
        c.SDL.SCANCODE_KP_MULTIPLY => .kp_multiply,
        c.SDL.SCANCODE_KP_MINUS => .kp_subtract,
        c.SDL.SCANCODE_KP_PLUS => .kp_add,
        c.SDL.SCANCODE_KP_ENTER => .kp_enter,
        c.SDL.SCANCODE_KP_0 => .kp_0,
        c.SDL.SCANCODE_KP_1 => .kp_1,
        c.SDL.SCANCODE_KP_2 => .kp_2,
        c.SDL.SCANCODE_KP_3 => .kp_3,
        c.SDL.SCANCODE_KP_4 => .kp_4,
        c.SDL.SCANCODE_KP_5 => .kp_5,
        c.SDL.SCANCODE_KP_6 => .kp_6,
        c.SDL.SCANCODE_KP_7 => .kp_7,
        c.SDL.SCANCODE_KP_8 => .kp_8,
        c.SDL.SCANCODE_KP_9 => .kp_9,
        c.SDL.SCANCODE_KP_PERIOD => .kp_decimal,

        c.SDL.SCANCODE_RETURN => .enter,
        c.SDL.SCANCODE_ESCAPE => .escape,
        c.SDL.SCANCODE_TAB => .tab,
        c.SDL.SCANCODE_LSHIFT => .left_shift,
        c.SDL.SCANCODE_RSHIFT => .right_shift,
        c.SDL.SCANCODE_LCTRL => .left_control,
        c.SDL.SCANCODE_RCTRL => .right_control,
        c.SDL.SCANCODE_LALT => .left_alt,
        c.SDL.SCANCODE_RALT => .right_alt,
        c.SDL.SCANCODE_LGUI => .left_command,
        c.SDL.SCANCODE_RGUI => .right_command,
        c.SDL.SCANCODE_MENU => .menu,
        c.SDL.SCANCODE_NUMLOCKCLEAR => .num_lock,
        c.SDL.SCANCODE_CAPSLOCK => .caps_lock,
        c.SDL.SCANCODE_PRINTSCREEN => .print,
        c.SDL.SCANCODE_SCROLLLOCK => .scroll_lock,
        c.SDL.SCANCODE_PAUSE => .pause,
        c.SDL.SCANCODE_DELETE => .delete,
        c.SDL.SCANCODE_HOME => .home,
        c.SDL.SCANCODE_END => .end,
        c.SDL.SCANCODE_PAGEUP => .page_up,
        c.SDL.SCANCODE_PAGEDOWN => .page_down,
        c.SDL.SCANCODE_INSERT => .insert,
        c.SDL.SCANCODE_LEFT => .left,
        c.SDL.SCANCODE_RIGHT => .right,
        c.SDL.SCANCODE_UP => .up,
        c.SDL.SCANCODE_DOWN => .down,
        c.SDL.SCANCODE_BACKSPACE => .backspace,
        c.SDL.SCANCODE_SPACE => .space,
        c.SDL.SCANCODE_MINUS => .minus,
        c.SDL.SCANCODE_EQUALS => .equal,
        c.SDL.SCANCODE_LEFTBRACKET => .left_bracket,
        c.SDL.SCANCODE_RIGHTBRACKET => .right_bracket,
        c.SDL.SCANCODE_BACKSLASH => .backslash,
        c.SDL.SCANCODE_SEMICOLON => .semicolon,
        c.SDL.SCANCODE_APOSTROPHE => .apostrophe,
        c.SDL.SCANCODE_COMMA => .comma,
        c.SDL.SCANCODE_PERIOD => .period,
        c.SDL.SCANCODE_SLASH => .slash,
        c.SDL.SCANCODE_GRAVE => .grave,

        else => blk: {
            log.debug("SDL_scancode_to_dvui unknown scancode {d}", .{scancode});
            break :blk .unknown;
        },
    };
}

//
// Error checking for vulkan and SDL
//

fn check_sdl(res: anytype) void {
    if (@TypeOf(res) == c_int) {
        if (res != 0) {
            log.err("Detected SDL error: {s}", .{c.SDL.GetError()});
            @panic("SDL error");
        }
    } else if (@TypeOf(res) == c.SDL.Bool) {
        if (res != true) {
            log.err("Detected SDL error: {s}", .{c.SDL.GetError()});
            @panic("SDL error");
        }
    } else {
        @compileError("unsupported SDL return type " ++ @typeName(@TypeOf(res)));
    }
}
