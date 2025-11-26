const std = @import("std");
const gpu = std.gpu;
const zm = @import("zmath");

const Vec2 = @Vector(2, f32);
const Vec3 = @Vector(3, f32);
const Vec4 = zm.Vec;
const Mat4 = zm.Mat;

extern var in_position: Vec3 addrspace(.input);
extern var in_normal: Vec3 addrspace(.input);
extern var in_color: Vec3 addrspace(.input);
extern var in_uv: Vec2 addrspace(.input);

extern var out_color: Vec3 addrspace(.output);
extern var out_uv: Vec2 addrspace(.output);

const UniformBufferObject = extern struct {
    view: Mat4,
    proj: Mat4,
    view_proj: Mat4,
};
extern const camera_data: UniformBufferObject addrspace(.uniform);

const ObjectData = extern struct {
    model: Mat4,
};
extern const object_buffer: ObjectData addrspace(.storage_buffer);

const PushConstants = extern struct {
    data: Vec4,
    render_matrix: Mat4,
};
extern const push_constants: PushConstants addrspace(.push_constant);

export fn main() callconv(.spirv_vertex) void {
    gpu.location(&in_position, 0);
    gpu.location(&in_normal, 1);
    gpu.location(&in_color, 2);
    gpu.location(&in_uv, 3);

    gpu.location(&out_color, 0);
    gpu.location(&out_uv, 1);

    gpu.binding(&camera_data, 0, 0);
    gpu.binding(&object_buffer, 1, 0);

    const transform = zm.mul(camera_data.view_proj, object_buffer.model);
    const position = Vec4{ in_position[0], in_position[1], in_position[2], 1.0 };
    gpu.position_out.* = zm.mul(transform, position);
    out_uv = in_uv;
    out_color = in_color;
}
