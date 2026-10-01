const std = @import("std");
const builtin = @import("builtin");

extern "c" fn _read(fd: c_int, buffer: [*]u8, count: c_uint) c_int;
extern "c" fn _write(fd: c_int, buffer: [*]const u8, count: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn readStdin(buf: []u8) isize {
    if (builtin.os.tag == .windows) {
        return _read(0, buf.ptr, @intCast(buf.len));
    } else {
        return std.c.read(0, buf.ptr, buf.len);
    }
}

fn writeStdout(msg: []const u8) void {
    if (builtin.os.tag == .windows) {
        _ = _write(1, msg.ptr, @intCast(msg.len));
    } else {
        _ = std.c.write(1, msg.ptr, msg.len);
    }
}

const ModelConfig = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8, // "ollama" o "openai"
    model: []const u8,
    endpoint: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
};

const AppConfig = struct {
    ollama_url: []const u8 = "http://127.0.0.1:11434",
    default_model: []const u8 = "llama3.2",
    models: []ModelConfig = &.{},
};

// ============================================================================
// Utilidades JSON y Ejecución HTTP (Curl)
// ============================================================================

fn escapeJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '\"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn getConfigPath() []const u8 {
    if (getenv("CONFIG_PATH")) |env_path| {
        const span = std.mem.span(env_path);
        if (span.len > 0) return span;
    }
    return "config.json";
}

fn readConfigData(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    // 1. Variable de entorno CONFIG_PATH si está definida
    if (getenv("CONFIG_PATH")) |env_path| {
        const path = std.mem.span(env_path);
        if (path.len > 0) {
            if (cwd.readFileAlloc(io, path, allocator, .unlimited)) |d| return d else |_| {}
        }
    }
    // 2. config.json en el directorio actual
    if (cwd.readFileAlloc(io, "config.json", allocator, .unlimited)) |d| return d else |_| {}
    // 3. config.json en el directorio padre (si el binario corre desde dist/)
    if (cwd.readFileAlloc(io, "../config.json", allocator, .unlimited)) |d| return d else |_| {}

    return null;
}

fn loadConfig(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(AppConfig) {
    if (readConfigData(allocator, io)) |data| {
        defer allocator.free(data);
        return try std.json.parseFromSlice(AppConfig, allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    std.debug.print("[Bridge-Zig] No se encontró config.json, usando valores por defecto\n", .{});
    const fallback = "{\"ollama_url\":\"http://127.0.0.1:11434\",\"default_model\":\"llama3.2\",\"models\":[]}";
    return try std.json.parseFromSlice(AppConfig, allocator, fallback, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn executeHttp(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = try std.process.run(allocator, io, .{
        .argv = argv,
    });
    defer allocator.free(res.stderr);
    return res.stdout;
}

// ============================================================================
// Consultas a Modelos (Ollama y OpenAI-Compatible)
// ============================================================================

fn callOllama(allocator: std.mem.Allocator, io: std.Io, ollama_url: []const u8, model: []const u8, prompt: []const u8) ![]u8 {
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/api/generate", .{ollama_url});
    defer allocator.free(endpoint);

    const escaped_prompt = try escapeJson(allocator, prompt);
    defer allocator.free(escaped_prompt);

    const payload = try std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"prompt\":\"{s}\",\"stream\":false}}", .{ model, escaped_prompt });
    defer allocator.free(payload);

    const argv = [_][]const u8{
        "curl", "-s", "-X", "POST", endpoint,
        "-H", "Content-Type: application/json",
        "-d", payload,
    };

    const stdout = try executeHttp(allocator, io, &argv);
    defer allocator.free(stdout);

    if (stdout.len == 0) {
        return try allocator.dupe(u8, "Error: Ollama no devolvió respuesta. Verifica que 'ollama serve' esté en ejecución.");
    }

    // Parsear campo "response"
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch {
        return try allocator.dupe(u8, stdout);
    };
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("response")) |resp| {
            if (resp == .string) {
                return try allocator.dupe(u8, resp.string);
            }
        }
        if (parsed.value.object.get("error")) |err_val| {
            if (err_val == .string) {
                return try std.fmt.allocPrint(allocator, "Error de Ollama: {s}", .{err_val.string});
            }
        }
    }

    return try allocator.dupe(u8, stdout);
}

fn callOpenAI(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8, model: []const u8, api_key_env: ?[]const u8, prompt: []const u8) ![]u8 {
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    if (api_key_env) |env_name| {
        // Encontrar valor de variable de entorno
        var env_name_z: [256]u8 = undefined;
        if (env_name.len < env_name_z.len) {
            @memcpy(env_name_z[0..env_name.len], env_name);
            env_name_z[env_name.len] = 0;
            if (getenv(env_name_z[0..env_name.len :0])) |val| {
                const key = std.mem.span(val);
                auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
            }
        }
    }

    const escaped_prompt = try escapeJson(allocator, prompt);
    defer allocator.free(escaped_prompt);

    const payload = try std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}", .{ model, escaped_prompt });
    defer allocator.free(payload);

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);

    try argv_list.appendSlice(allocator, &[_][]const u8{ "curl", "-s", "-X", "POST", endpoint, "-H", "Content-Type: application/json" });
    if (auth_header) |h| {
        try argv_list.appendSlice(allocator, &[_][]const u8{ "-H", h });
    }
    try argv_list.appendSlice(allocator, &[_][]const u8{ "-d", payload });

    const stdout = try executeHttp(allocator, io, argv_list.items);
    defer allocator.free(stdout);

    if (stdout.len == 0) {
        return try allocator.dupe(u8, "Error: Endpoint cloud no devolvió respuesta.");
    }

    // Parsear campo "choices[0].message.content"
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch {
        return try allocator.dupe(u8, stdout);
    };
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const first = choices.array.items[0];
                if (first == .object) {
                    if (first.object.get("message")) |msg| {
                        if (msg == .object) {
                            if (msg.object.get("content")) |content| {
                                if (content == .string) {
                                    return try allocator.dupe(u8, content.string);
                                }
                            }
                        }
                    }
                }
            }
        }
        if (parsed.value.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("message")) |msg| {
                    if (msg == .string) {
                        return try std.fmt.allocPrint(allocator, "Error API Cloud: {s}", .{msg.string});
                    }
                }
            }
        }
    }

    return try allocator.dupe(u8, stdout);
}

// ============================================================================
// Handlers de Herramientas MCP
// ============================================================================

fn handleAskOllama(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ![]u8 {
    const config_parsed = try loadConfig(allocator, io);
    defer config_parsed.deinit();

    const prompt_val = if (args == .object) args.object.get("prompt") else null;
    const prompt = if (prompt_val) |p| (if (p == .string) p.string else "") else "";

    if (prompt.len == 0) {
        return try allocator.dupe(u8, "Error: Debes proporcionar un 'prompt'.");
    }

    var model = config_parsed.value.default_model;
    if (args == .object) {
        if (args.object.get("model")) |m| {
            if (m == .string and m.string.len > 0) {
                model = m.string;
            }
        }
    }

    return try callOllama(allocator, io, config_parsed.value.ollama_url, model, prompt);
}

fn handleAskModel(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ![]u8 {
    const config_parsed = try loadConfig(allocator, io);
    defer config_parsed.deinit();

    const model_id_val = if (args == .object) args.object.get("model_id") else null;
    const model_id = if (model_id_val) |m| (if (m == .string) m.string else "") else "";

    const prompt_val = if (args == .object) args.object.get("prompt") else null;
    const prompt = if (prompt_val) |p| (if (p == .string) p.string else "") else "";

    if (model_id.len == 0 or prompt.len == 0) {
        return try allocator.dupe(u8, "Error: Debes proporcionar 'model_id' y 'prompt'.");
    }

    // Buscar en los modelos configurados
    for (config_parsed.value.models) |m| {
        if (std.mem.eql(u8, m.id, model_id)) {
            if (std.mem.eql(u8, m.provider, "ollama")) {
                const url = m.endpoint orelse config_parsed.value.ollama_url;
                return try callOllama(allocator, io, url, m.model, prompt);
            } else if (std.mem.eql(u8, m.provider, "openai")) {
                const endpoint = m.endpoint orelse return try allocator.dupe(u8, "Error: El modelo OpenAI no tiene 'endpoint' configurado.");
                return try callOpenAI(allocator, io, endpoint, m.model, m.api_key_env, prompt);
            } else {
                return try std.fmt.allocPrint(allocator, "Error: Proveedor desconocido '{s}'.", .{m.provider});
            }
        }
    }

    // Si no está en models, pero coincide con default_model o es una llamada directa a Ollama
    return try callOllama(allocator, io, config_parsed.value.ollama_url, model_id, prompt);
}

fn handleListModels(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const config_parsed = try loadConfig(allocator, io);
    defer config_parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "🤖 Modelos Disponibles en config.json:\n\n");
    const header = try std.fmt.allocPrint(allocator, "• [Predeterminado Ollama]: {s} (URL: {s})\n\n", .{ config_parsed.value.default_model, config_parsed.value.ollama_url });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    for (config_parsed.value.models, 1..) |m, idx| {
        const item = try std.fmt.allocPrint(
            allocator,
            "{d}. ID: `{s}` | Nombre: {s}\n   - Proveedor: {s}\n   - Modelo API: {s}\n   - Endpoint: {s}\n\n",
            .{ idx, m.id, m.name, m.provider, m.model, m.endpoint orelse "(default)" },
        );
        defer allocator.free(item);
        try out.appendSlice(allocator, item);
    }

    return try out.toOwnedSlice(allocator);
}

fn handleAddModel(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ![]u8 {
    if (args != .object) {
        return try allocator.dupe(u8, "Error: argumentos inválidos.");
    }

    const id_val = args.object.get("id") orelse return try allocator.dupe(u8, "Falta 'id'");
    const name_val = args.object.get("name") orelse id_val;
    const provider_val = args.object.get("provider") orelse return try allocator.dupe(u8, "Falta 'provider' ('ollama' o 'openai')");
    const model_val = args.object.get("model") orelse return try allocator.dupe(u8, "Falta 'model'");
    const endpoint_val = args.object.get("endpoint");
    const env_val = args.object.get("api_key_env");

    if (id_val != .string or provider_val != .string or model_val != .string) {
        return try allocator.dupe(u8, "Error: tipos de argumentos inválidos.");
    }

    const data = readConfigData(allocator, io) orelse {
        return try allocator.dupe(u8, "Error: no se encontró config.json para modificar.");
    };
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try allocator.dupe(u8, "Error: config.json raíz no es un objeto.");
    }

    const models_ptr = parsed.value.object.getPtr("models");
    if (models_ptr == null or models_ptr.?.* != .array) {
        return try allocator.dupe(u8, "Error: campo 'models' inválido en config.json.");
    }

    var new_model_obj: std.json.ObjectMap = .empty;
    try new_model_obj.put(allocator, "id", .{ .string = id_val.string });
    try new_model_obj.put(allocator, "name", .{ .string = if (name_val == .string) name_val.string else id_val.string });
    try new_model_obj.put(allocator, "provider", .{ .string = provider_val.string });
    try new_model_obj.put(allocator, "model", .{ .string = model_val.string });
    if (endpoint_val) |ep| {
        if (ep == .string) try new_model_obj.put(allocator, "endpoint", .{ .string = ep.string });
    }
    if (env_val) |ev| {
        if (ev == .string) try new_model_obj.put(allocator, "api_key_env", .{ .string = ev.string });
    }

    try models_ptr.?.*.array.append(.{ .object = new_model_obj });

    // Serializar de vuelta a config.json
    const json_out = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
    defer allocator.free(json_out);

    const cwd = std.Io.Dir.cwd();
    const target_path = getConfigPath();
    try cwd.writeFile(io, .{
        .sub_path = target_path,
        .data = json_out,
    });

    return try std.fmt.allocPrint(allocator, "✅ Modelo '{s}' añadido exitosamente a {s}.", .{ id_val.string, target_path });
}

// ============================================================================
// Despachador de Protocolo JSON-RPC (MCP)
// ============================================================================

fn sendResponse(msg: []const u8) void {
    writeStdout(msg);
    writeStdout("\n");
}

fn handleToolsList(allocator: std.mem.Allocator, id_json: []const u8) !void {
    const tools_json = try std.fmt.allocPrint(
        allocator,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"tools":[
        \\{{"name":"ask_ollama","description":"Consulta un modelo local corriendo en Ollama (ej: llama3.2, deepseek-r1, qwen2.5-coder).","inputSchema":{{"type":"object","properties":{{"prompt":{{"type":"string","description":"Mensaje o pregunta para el modelo."}},"model":{{"type":"string","description":"Nombre del modelo de Ollama (opcional, usa el predeterminado si se omite)."}}}},"required":["prompt"]}}}},
        \\{{"name":"ask_model","description":"Consulta cualquiera de los modelos configurados en config.json por su ID o alias (locales o en la nube).","inputSchema":{{"type":"object","properties":{{"model_id":{{"type":"string","description":"ID del modelo registrado (ej: 'llama3.2', 'groq', 'cerebras', 'deepseek', etc.)."}},"prompt":{{"type":"string","description":"Mensaje o instrucción para el modelo."}}}},"required":["model_id","prompt"]}}}},
        \\{{"name":"list_models","description":"Lista todos los modelos configurados actualmente en config.json con sus proveedores.","inputSchema":{{"type":"object","properties":{{}}}}}},
        \\{{"name":"add_model","description":"Agrega un nuevo modelo a config.json dinámicamente sin reiniciar ni recompilar.","inputSchema":{{"type":"object","properties":{{"id":{{"type":"string","description":"ID único del modelo (ej: 'mi-llama', 'groq-mixtral')."}},"name":{{"type":"string","description":"Nombre descriptivo."}},"provider":{{"type":"string","description":"'ollama' o 'openai'."}},"model":{{"type":"string","description":"Nombre real del modelo en la API."}},"endpoint":{{"type":"string","description":"URL del endpoint (opcional para Ollama, obligatoria para APIs OpenAI-compatibles)."}},"api_key_env":{{"type":"string","description":"Nombre de la variable de entorno con el API key (opcional)."}}}},"required":["id","provider","model"]}}}}
        \\]}}}}
    ,
        .{id_json},
    );
    defer allocator.free(tools_json);
    sendResponse(tools_json);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("[Bridge-Zig] Servidor MCP Antigravity iniciado\n", .{});

    var buf: [65536 * 4]u8 = undefined;
    var len: usize = 0;

    while (true) {
        const n = readStdin(buf[len..]);
        if (n <= 0) break;
        len += @intCast(n);

        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |newline_idx| {
            var line = buf[0..newline_idx];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            if (line.len > 0) {
                // Parsear mensaje JSON-RPC
                var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
                    // Descartar línea inválida
                    const rem_start = newline_idx + 1;
                    const rem_len = len - rem_start;
                    if (rem_len > 0) std.mem.copyForwards(u8, buf[0..rem_len], buf[rem_start..len]);
                    len = rem_len;
                    continue;
                };
                defer parsed.deinit();

                if (parsed.value == .object) {
                    const method_val = parsed.value.object.get("method");
                    const id_val = parsed.value.object.get("id");

                    if (method_val != null and method_val.? == .string) {
                        const method = method_val.?.string;

                        if (std.mem.eql(u8, method, "initialize")) {
                            const id_str = if (id_val != null and id_val.? == .integer)
                                try std.fmt.allocPrint(allocator, "{d}", .{id_val.?.integer})
                            else
                                try allocator.dupe(u8, "1");
                            defer allocator.free(id_str);

                            const resp = try std.fmt.allocPrint(
                                allocator,
                                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"antigravity-zig-bridge\",\"version\":\"1.0.0\"}}}}}}",
                                .{id_str},
                            );
                            defer allocator.free(resp);
                            sendResponse(resp);
                        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
                            // ACK silencioso
                        } else if (std.mem.eql(u8, method, "ping")) {
                            if (id_val) |id| {
                                const id_str = if (id == .integer) try std.fmt.allocPrint(allocator, "{d}", .{id.integer}) else try allocator.dupe(u8, "1");
                                defer allocator.free(id_str);
                                const resp = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id_str});
                                defer allocator.free(resp);
                                sendResponse(resp);
                            }
                        } else if (std.mem.eql(u8, method, "tools/list")) {
                            const id_str = if (id_val != null and id_val.? == .integer)
                                try std.fmt.allocPrint(allocator, "{d}", .{id_val.?.integer})
                            else
                                try allocator.dupe(u8, "1");
                            defer allocator.free(id_str);

                            try handleToolsList(allocator, id_str);
                        } else if (std.mem.eql(u8, method, "tools/call")) {
                            const id_str = if (id_val != null and id_val.? == .integer)
                                try std.fmt.allocPrint(allocator, "{d}", .{id_val.?.integer})
                            else
                                try allocator.dupe(u8, "1");
                            defer allocator.free(id_str);

                            const params_val = parsed.value.object.get("params");
                            var result_text: []u8 = undefined;
                            var is_error = false;

                            if (params_val != null and params_val.? == .object) {
                                const tool_name_val = params_val.?.object.get("name");
                                const args_val = params_val.?.object.get("arguments") orelse std.json.Value{ .null = {} };

                                if (tool_name_val != null and tool_name_val.? == .string) {
                                    const tool_name = tool_name_val.?.string;

                                    if (std.mem.eql(u8, tool_name, "ask_ollama")) {
                                        result_text = handleAskOllama(allocator, io, args_val) catch |err| blk: {
                                            is_error = true;
                                            break :blk try std.fmt.allocPrint(allocator, "Error ejecutando ask_ollama: {any}", .{err});
                                        };
                                    } else if (std.mem.eql(u8, tool_name, "ask_model")) {
                                        result_text = handleAskModel(allocator, io, args_val) catch |err| blk: {
                                            is_error = true;
                                            break :blk try std.fmt.allocPrint(allocator, "Error ejecutando ask_model: {any}", .{err});
                                        };
                                    } else if (std.mem.eql(u8, tool_name, "list_models")) {
                                        result_text = handleListModels(allocator, io) catch |err| blk: {
                                            is_error = true;
                                            break :blk try std.fmt.allocPrint(allocator, "Error ejecutando list_models: {any}", .{err});
                                        };
                                    } else if (std.mem.eql(u8, tool_name, "add_model")) {
                                        result_text = handleAddModel(allocator, io, args_val) catch |err| blk: {
                                            is_error = true;
                                            break :blk try std.fmt.allocPrint(allocator, "Error ejecutando add_model: {any}", .{err});
                                        };
                                    } else {
                                        is_error = true;
                                        result_text = try std.fmt.allocPrint(allocator, "Herramienta desconocida: {s}", .{tool_name});
                                    }
                                } else {
                                    is_error = true;
                                    result_text = try allocator.dupe(u8, "Falta nombre de herramienta en params.");
                                }
                            } else {
                                is_error = true;
                                result_text = try allocator.dupe(u8, "Falta objeto params.");
                            }
                            defer allocator.free(result_text);

                            const escaped_res = try escapeJson(allocator, result_text);
                            defer allocator.free(escaped_res);

                            const resp = try std.fmt.allocPrint(
                                allocator,
                                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"isError\":{s}}}}}",
                                .{ id_str, escaped_res, if (is_error) "true" else "false" },
                            );
                            defer allocator.free(resp);
                            sendResponse(resp);
                        }
                    }
                }
            }

            // Desplazar lo restante en el buffer
            const rem_start = newline_idx + 1;
            const rem_len = len - rem_start;
            if (rem_len > 0) {
                std.mem.copyForwards(u8, buf[0..rem_len], buf[rem_start..len]);
            }
            len = rem_len;
        }
    }
}
