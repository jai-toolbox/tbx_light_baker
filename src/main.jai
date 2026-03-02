/*

I was about to start figuring out what's taking so long with direct lighting using our logging method or whatnot.

*/

#import "tbx/texture_packing";
#import "tbx/model_loading";
#import "tbx/geometry";
#import "tbx/opengl";
#import "tbx/engine";
#import "tbx/section_logger";

#import "tbx/light_baking";

#import "Hash_Table";
#import "Basic";
#import "GL";
#import "Math";
#import "String";

Packed_Texture_Rendering_2_Channel :: struct {
    renderables: [..] Camera_Per_Object_Transform_Packed_Texture_2_Channel_Renderable;
    renderer: Camera_Per_Object_Transform_Packed_Texture_2_Channel_Renderer;

    using #as base: Packed_Texture_Rendering_Base;

    // We keep references to the bake scene so we can look up lightmap UVs
    bake_scene: *Bake_Scene;
    lightmap_lookup: Packed_Texture_Lookup;
    has_lightmap: bool;
}

init :: (using ptr: *Packed_Texture_Rendering_2_Channel) {
    init(*renderer);
    init(*base);

    // Tell the shader which texture units correspond to which samplers
    glUseProgram(renderer.shader_program_gl_handle);
    set_packed_textures_uniform(*renderer, 0);
    set_packed_texture_bounding_boxes_uniform(*renderer, 1);
    glUseProgram(0);
}

// register the baked lightmap as a packed texture so the renderer can sample it.
// this assumes the lightmap png has already been written and then packed into the
// packed texture system. Alternatively we could upload it directly as an extra layer.
register_lightmap :: (using ptr: *Packed_Texture_Rendering_2_Channel, lightmap_path: string) {
    lookup_table := build_packed_texture_lookup_table(*metadata);
    defer deinit(*lookup_table);

    lightmap_lookup, has_lightmap = find_packed_texture(*lookup_table, lightmap_path);
    if !has_lightmap {
        log_error("Could not find lightmap '%' in packed textures", lightmap_path);
    }
}

set_bake_scene :: (using ptr: *Packed_Texture_Rendering_2_Channel, scene: *Bake_Scene) {
    bake_scene = scene;
}

// remap a local [0,1] uv into the packed atlas sub-region, accounting for OpenGL vertical flip.
// the new convention stores {u_min, v_min, width, height} in bounding boxes with v_min already
// flipped in the base init, so we apply the same transform here on the CPU side.
remap_uv_to_atlas :: (tc: Vector2, tex: Packed_Texture, side: int) -> Vector2 {
    u_min  := cast(float) tex.top_left_x / cast(float) side;
    v_min  := cast(float) tex.top_left_y / cast(float) side;
    width  := cast(float) tex.w          / cast(float) side;
    height := cast(float) tex.h          / cast(float) side;

    // match the OpenGL flip that init applies to the bounding boxes
    v_min = 1.0 - v_min - height;

    // fmod to handle tiling, then shift into the sub-region
    u := u_min + (tc.x - floor(tc.x)) * width;
    v := v_min + (tc.y - floor(tc.y)) * height;
    return .{u, v};
}

load_gltf_into_packed_texture_2_channel_renderables :: (
    gltf: *Gltf_Data,
    bake_scene: *Bake_Scene,
    metadata: *Packed_Textures_Metadata,
    renderer: *Camera_Per_Object_Transform_Packed_Texture_2_Channel_Renderer,
    lightmap_lookup: Packed_Texture_Lookup,
    has_lightmap: bool
) -> [..] Camera_Per_Object_Transform_Packed_Texture_2_Channel_Renderable {
    slog_scoped("load gltf");

    renderables: [..] Camera_Per_Object_Transform_Packed_Texture_2_Channel_Renderable;

    lookup_table := build_packed_texture_lookup_table(metadata);

    // we track a global triangle index across all meshes so we can correlate
    // with the bake_scene tiles (which were built in the same mesh/triangle order).
    global_tri_index := 0;

    for mesh_idx: 0..gltf.all_meshes.count - 1 {
        gltf_mesh := *gltf.all_meshes[mesh_idx];

        for *prim: gltf_mesh.primitives {
            if prim.position_accessor < 0 continue;
            if prim.mode != .TRIANGLES continue;

            renderable: Camera_Per_Object_Transform_Packed_Texture_2_Channel_Renderable;

            // read positions
            positions := read_accessor_as_vector3_array(gltf, prim.position_accessor);

            // read normals
            normals: [..] Vector3;
            if prim.normal_accessor >= 0 {
                norm_data := read_accessor_as_vector3_array(gltf, prim.normal_accessor);
                for norm_data array_add(*normals, it);
            } else {
                for 0..positions.count-1 array_add(*normals, .{0, 1, 0});
            }

            // texture coordinates for channel 0 (base color)
            texcoords_0: [..] Vector2;
            tc0_accessor := get_texcoord_accessor(prim, 0);
            if tc0_accessor >= 0 {
                tc_data := read_accessor_as_vector2_array(gltf, tc0_accessor);
                for tc_data array_add(*texcoords_0, it);
            } else {
                for 0..positions.count-1 array_add(*texcoords_0, .{0, 0});
            }

            indices: [..] u32;
            if prim.indices_accessor >= 0 {
                idx_data := read_accessor_as_index_array(gltf, prim.indices_accessor);
                for idx_data array_add(*indices, it);
            } else {
                for i: 0..cast(u32)(positions.count - 1) {
                    array_add(*indices, i);
                }
            }

            // resolve base color texture for channel 0
            base_color_lookup: Packed_Texture_Lookup;
            has_base_color := false;

            if prim.material_index >= 0 && prim.material_index < gltf.all_materials.count {
                mat := *gltf.all_materials[prim.material_index];
                tex_index := mat.pbr_metallic_roughness.base_color_texture.texture_index;
                if tex_index >= 0 {
                    tex_path := resolve_gltf_image_path(gltf, tex_index);
                    if tex_path.count > 0 {
                        // decode %20 to space so the path matches what's stored in metadata
                        decoded_path := replace(tex_path, "%20", " ");
                        base_color_lookup, has_base_color = find_packed_texture(*lookup_table, decoded_path);
                        if !has_base_color {
                            log_error("Could not find base color texture '%' in packed textures", decoded_path);
                        } else {
                            log("Found base color texture % in packed textures lookup", decoded_path);
                        }
                    }
                }
            }

            // build lightmap uvs for channel 1
            tri_count := indices.count / 3;

            expanded_positions: [..] Vector3;
            expanded_texcoords_0: [..] Vector2;
            expanded_texcoords_1: [..] Vector2;
            expanded_indices: [..] u32;
            expanded_packed_texture_index_0: [..] s32;
            expanded_packed_texture_bb_index_0: [..] s32;
            expanded_packed_texture_index_1: [..] s32;
            expanded_packed_texture_bb_index_1: [..] s32;

            vertex_cursor: u32 = 0;

            for tri_idx: 0..tri_count - 1 {
                i0 := indices[tri_idx * 3 + 0];
                i1 := indices[tri_idx * 3 + 1];
                i2 := indices[tri_idx * 3 + 2];

                p0 := positions[i0];
                p1 := positions[i1];
                p2 := positions[i2];

                tc0_v0 := texcoords_0[i0];
                tc0_v1 := texcoords_0[i1];
                tc0_v2 := texcoords_0[i2];

                // remap base color UVs into the packed atlas sub-region.
                // remap_uv_to_atlas now handles the OpenGL vertical flip internally,
                // so we no longer need the separate tc.y = 1.0 - tc.y flip afterwards.
                if has_base_color {
                    base_tex := metadata.textures[base_color_lookup.metadata_index];
                    tc0_v0 = remap_uv_to_atlas(tc0_v0, base_tex, metadata.side_length_px);
                    tc0_v1 = remap_uv_to_atlas(tc0_v1, base_tex, metadata.side_length_px);
                    tc0_v2 = remap_uv_to_atlas(tc0_v2, base_tex, metadata.side_length_px);
                }

                // compute lightmap uvs from the bake scene tile
                lm_uv0 := Vector2.{0, 0};
                lm_uv1 := Vector2.{0, 0};
                lm_uv2 := Vector2.{0, 0};

                if bake_scene != null && global_tri_index < bake_scene.tiles.count {
                    sorted_tile_idx := bake_scene.tri_to_tile[global_tri_index];
                    tile := *bake_scene.tiles[sorted_tile_idx];
                    placement := tile.block.packed_placement;

                    if placement != null {
                        atlas_w := cast(float) bake_scene.atlas.width;
                        atlas_h := cast(float) bake_scene.atlas.height;

                        lm_uv0 = compute_lightmap_uv(p0, tile, atlas_w, atlas_h);
                        lm_uv1 = compute_lightmap_uv(p1, tile, atlas_w, atlas_h);
                        lm_uv2 = compute_lightmap_uv(p2, tile, atlas_w, atlas_h);
                    }
                }

                tri_verts := Vector3.[p0, p1, p2];
                tri_tc0   := Vector2.[tc0_v0, tc0_v1, tc0_v2];
                tri_tc1   := Vector2.[lm_uv0, lm_uv1, lm_uv2];

                for vi: 0..2 {
                    array_add(*expanded_positions, tri_verts[vi]);
                    array_add(*expanded_texcoords_0, tri_tc0[vi]);
                    array_add(*expanded_texcoords_1, tri_tc1[vi]);

                    if has_base_color {
                        array_add(*expanded_packed_texture_index_0, base_color_lookup.container_index);
                        array_add(*expanded_packed_texture_bb_index_0, base_color_lookup.metadata_index);
                    } else {
                        array_add(*expanded_packed_texture_index_0, 0);
                        array_add(*expanded_packed_texture_bb_index_0, 0);
                    }

                    if has_lightmap {
                        array_add(*expanded_packed_texture_index_1, lightmap_lookup.container_index);
                        array_add(*expanded_packed_texture_bb_index_1, lightmap_lookup.metadata_index);
                    } else {
                        array_add(*expanded_packed_texture_index_1, 0);
                        array_add(*expanded_packed_texture_bb_index_1, 0);
                    }

                    array_add(*expanded_indices, vertex_cursor);
                    vertex_cursor += 1;
                }

                global_tri_index += 1;
            }

            renderable.positions                           = expanded_positions;
            renderable.texture_coordinates_0               = expanded_texcoords_0;
            renderable.packed_texture_index_0               = expanded_packed_texture_index_0;
            renderable.packed_texture_bounding_box_index_0  = expanded_packed_texture_bb_index_0;
            renderable.texture_coordinates_1               = expanded_texcoords_1;
            renderable.packed_texture_index_1               = expanded_packed_texture_index_1;
            renderable.packed_texture_bounding_box_index_1  = expanded_packed_texture_bb_index_1;
            renderable.indices                             = expanded_indices;

            success := buffer_object(renderer, *renderable);
            if !success {
                log_error("Failed to buffer glTF primitive into 2-channel packed texture renderer");
            }

            array_add(*renderables, renderable);
        }
    }

    return renderables;
}

load_gltf_model :: (using ptr: *Packed_Texture_Rendering_2_Channel, gltf_path: string) {
    gltf_data := load_gltf(gltf_path);
    new_renderables := load_gltf_into_packed_texture_2_channel_renderables(
        *gltf_data,
        bake_scene,
        *metadata,
        *renderer,
        lightmap_lookup,
        has_lightmap
    );
    for new_renderables {
        array_add(*renderables, it);
    }
}

compute_lightmap_uv :: (world_pos: Vector3, tile: *Triangle_Lightmap_Tile, atlas_width: float, atlas_height: float) -> Vector2 {
    placement := tile.block.packed_placement;
    if placement == null return .{0, 0};

    // project world position into the tile's 2d tangent-space
    rel := world_pos - tile.p0;
    u_local := dot(rel, tile.tangent);
    v_local := dot(rel, tile.bitangent);

    // convert from world-space offset to pixel offset within the tile
    px := (u_local - tile.world_min.x) * cast(float) PIXELS_PER_UNIT;
    py := (v_local - tile.world_min.y) * cast(float) PIXELS_PER_UNIT;

    // convert to atlas uv
    atlas_u := (cast(float) placement.top_left_x + px) / atlas_width;
    atlas_v := (cast(float) placement.top_left_y + py) / atlas_height;

    // account for OpenGL vertical flip: the packed texture images are flipped
    // on load (stbi_set_flip_vertically_on_load(1)), so the lightmap atlas
    // coordinates need to be flipped to match.
    atlas_v = 1.0 - atlas_v;

    return .{atlas_u, atlas_v};
}

render :: (using packed_texture_rendering: *Packed_Texture_Rendering_2_Channel) {
    bind_packed_textures(base);
    render(*renderer);
}


main :: () {
    // We do a first pass of texture packing for the base color textures.
    // The lightmap will be added in a second pass after baking.

    ATLAS_SIZE :: 1024;
    GLTF_PATH :: "data/griffin_statue/griffin_statue.gltf";
    // GLTF_PATH :: "data/simple_cube/simple_cube.gltf";
    // GLTF_PATH :: "data/shrine/shrine.gltf";
    LIGHTMAP_PATH :: "data/lightmap_final.png";

    print("=== LIGHTMAP BAKING ===\n");

    gltf_data := load_gltf(GLTF_PATH);

    bake_scene := init_bake_scene(*gltf_data, ATLAS_SIZE, ATLAS_SIZE);
    defer free_bake_scene(*bake_scene);

    sun := make_directional_light(.{-1.0, 1.0, 1.0}, .{1.0, 0.8, 0.8}, 3.5);
    array_add(*bake_scene.lights, sun);

    // fill := make_point_light(.{2, 3, -1}, .{0.4, 0.5, 0.8}, 5.0, radius = 20.0);
    // array_add(*bake_scene.lights, fill);

    config: Bake_Config;
    config.do_direct_lighting   = true;
    config.do_ambient_occlusion = false;
    config.do_indirect_lighting = false;
    config.ao_samples           = 64;
    config.bounce_samples       = 128;
    config.max_bounces          = 2;

    bake_lightmap(*bake_scene, config);

    write_lightmap_png(LIGHTMAP_PATH, *bake_scene.atlas);
    write_lightmap_hdr("lightmap_final.hdr", *bake_scene.atlas);
    write_lightmap_debug_direct("lightmap_direct.png", *bake_scene.atlas);
    write_lightmap_debug_ao("lightmap_ao.png", *bake_scene.atlas);
    write_lightmap_debug_normals("lightmap_normals.png", *bake_scene.atlas);

    print("=== BAKING COMPLETE ===\n\n");

    // This ensures the lightmap PNG is included in the packed texture atlas.
    // force=true because we just wrote the lightmap and need it repacked.
    pack_textures(1024, force = true);

    defer print("Program ended gracefully, if you stop seeing this then something bad happened.\n");

    wp3: Windowed_Program_3D;
    wp3.vsync = false;
    wp3.movement_mode = .GOD;
    wp3.window_name = "tbx_light_baker";
    init(*wp3);

    packed_rendering: Packed_Texture_Rendering_2_Channel;
    init(*packed_rendering);

    set_bake_scene(*packed_rendering, *bake_scene);
    register_lightmap(*packed_rendering, LIGHTMAP_PATH);

    // this reads the gltf again (or we could reuse gltf_data), builds renderables
    // with channel 0 = base color UVs and channel 1 = lightmap UVs.
    load_gltf_model(*packed_rendering, GLTF_PATH);

    start_time := current_time_monotonic();

    while !wp3.end_program {
        mark_frame_start(*wp3);
        per_frame_update(*wp3);

        glUseProgram(packed_rendering.renderer.shader_program_gl_handle);
        set_world_to_camera_uniform(*packed_rendering.renderer, wp3.camera.world_to_camera);
        set_camera_to_clip_uniform(*packed_rendering.renderer, wp3.camera.camera_to_clip);

        for packed_rendering.renderables {
            queue_render(*packed_rendering.renderer, it.object_index);
        }

        Simp :: #import "Simp";
        Simp.update_window(wp3.window);
        Simp.clear_render_target(.15, .08, .08, 1);

        if wp3.current_menu == .NONE {
            glDepthMask(GL_TRUE);
            glEnable(GL_DEPTH_TEST);
            glClear(GL_DEPTH_BUFFER_BIT);

            render(*wp3.camera_per_object_transform_color_renderer);

            render(*packed_rendering);

            context.simp.current_shader = null;

            render_tick_stats(*wp3);
            render_movement_stats(*wp3);
            render_camera_stats(*wp3);
        } else {
            context.simp.current_shader = null;
            render_menus(*wp3.wp);
        }

        Simp.swap_buffers(wp3.window, false);

        sleep_to_maintain_max_fps(*wp3);
        mark_frame_end(*wp3);
    }
}
