#import "tbx/light_baking";

#import "Basic";
#import "Command_Line";
#import "File";
#import "File_Utilities";
#import "tbx/engine/windowed_program_3d_base";

DEFAULT_MAPS_ROOT :: "/home/cjm/projects/frag-z-organization/client_server_pair/client/data/maps";

Light_Baking_Options :: struct {
    bake := ""; @"?Bake lighting for the named map and exit after saving artifacts.";
    view := ""; @"?View previously baked lighting for the named map.";
    maps_root := DEFAULT_MAPS_ROOT; @"?Directory containing the map directories.";
}

construct_map_gltf_path :: (maps_root: string, map_name: string) -> string {
    return sprint("%1/%2/export/gltf/%2.gltf", maps_root, map_name);
}

construct_baked_lighting_directory :: (maps_root: string, map_name: string) -> string {
    return sprint("%/%/export/baked_lighting", maps_root, map_name);
}

main :: () {
    ok, options, was_set, inputs := parse_arguments(Light_Baking_Options);
    defer array_free(inputs);
    defer {
        if was_set.bake free(options.bake);
        if was_set.view free(options.view);
        if was_set.maps_root free(options.maps_root);
    }
    if !ok return;

    if inputs.count > 0 {
        print("Unexpected positional argument: %\n", inputs[0]);
        print("Use -help to list the available arguments.\n");
        return;
    }

    if was_set.bake == was_set.view {
        print("Specify exactly one of -bake or -view. Use -help for details.\n");
        return;
    }

    run_mode := ifx was_set.bake then Light_Baking_Run_Mode.BAKE else .VIEW;
    map_name := ifx was_set.bake then options.bake else options.view;

    source_gltf_path := construct_map_gltf_path(options.maps_root, map_name);
    defer free(source_gltf_path);

    baked_lighting_directory := construct_baked_lighting_directory(options.maps_root, map_name);
    defer free(baked_lighting_directory);
    baked_lighting_path := sprint("%/baked_lighting.bin", baked_lighting_directory);
    defer free(baked_lighting_path);
    reflection_probes_path := sprint("%/reflection_probes.bin", baked_lighting_directory);
    defer free(reflection_probes_path);
    light_probes_path := sprint("%/light_probes.bin", baked_lighting_directory);
    defer free(light_probes_path);


    if !file_exists(source_gltf_path) {
        print("Could not find the map glTF: %\n", source_gltf_path);
        return;
    }

    if run_mode == .BAKE {
        if !make_directory_if_it_does_not_exist(baked_lighting_directory, recursive = true) {
            print("Could not create the baked lighting directory: %\n", baked_lighting_directory);
            return;
        }
    } else {
        if !file_exists(baked_lighting_path) {
            print("Could not find baked lighting: %\n", baked_lighting_path);
            return;
        }
        if !file_exists(reflection_probes_path) {
            print("Could not find reflection probes: %\n", reflection_probes_path);
            return;
        }
        if !file_exists(light_probes_path) {
            print("Could not find light probes: %\n", light_probes_path);
            return;
        }
    }

    light_baking_context: Light_Baking_Context;
    light_baking_context.source_gltf_path = source_gltf_path;
    light_baking_context.baked_lighting_path = baked_lighting_path;
    light_baking_context.reflection_probes_path = reflection_probes_path;
    light_baking_context.light_probes_path = light_probes_path;

    light_baking_program: Light_Baking_Program;
    light_baking_program.window_name = ifx run_mode == .BAKE then "Light Bake" else "Baked Lighting Viewer";
    light_baking_program.camera.position = .{5, 8, 85};
    light_baking_program.movement_mode = .GOD;

    init(*light_baking_program, *light_baking_context, run_mode);
    defer {
        // The baking context owns capture renderables that borrow the runtime
        // renderables' CPU arrays, so it must be released first.
        deinit(*light_baking_context);
        deinit(*light_baking_program);
    }

    // The engine defaults to 144 FPS. The viewer is also used for renderer
    // performance work, so keep its software limiter above the 300 FPS goal.
    light_baking_program.desired_max_fps = 512;
    set_max_fps(*light_baking_program.wp3, 512);

    if run_mode == .BAKE return;

    while !light_baking_program.end_program {
        mark_frame_start(*light_baking_program.wp3);
        per_frame_update(*light_baking_program, *light_baking_context);
        render_scene(*light_baking_program);
        sleep_to_maintain_max_fps(*light_baking_program.wp3);
        mark_frame_end(*light_baking_program.wp3);
    }
}
