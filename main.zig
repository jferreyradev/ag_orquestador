const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Funciones C / POSIX y Wrappers Multiplataforma
// ============================================================================

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

// ============================================================================
// Tipos y Estructuras de Configuración y Telemetría
// ============================================================================

const ModelConfig = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8, // "ollama" o "openai"
    model: []const u8,
    endpoint: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api_keys: ?[][]const u8 = null,
};

const AppConfig = struct {
    ollama_url: []const u8 = "http://127.0.0.1:11434",
    default_model: []const u8 = "qwen2.5-coder:7b",
    fallback_chain: [][]const u8 = &.{},
    models: []ModelConfig = &.{},
};

const CallResult = struct {
    text: []u8,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    http_status: u16 = 200,
    success: bool = false,
    model_name: []const u8 = "",
};

// Estadísticas de consumo de la sesión
var stat_calls_count: u64 = 0;
var stat_prompt_tokens: u64 = 0;
var stat_completion_tokens: u64 = 0;
var stat_fallbacks_count: u64 = 0;

// ============================================================================
// Rutas de Configuración Dinámica
// ============================================================================

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
    // 2. config.local.json en el directorio actual (prioridad privada, ya en .gitignore)
    if (cwd.readFileAlloc(io, "config.local.json", allocator, .unlimited)) |d| return d else |_| {}
    // 3. config.json en el directorio actual
    if (cwd.readFileAlloc(io, "config.json", allocator, .unlimited)) |d| return d else |_| {}
    // 4. Si el binario corre desde dist/ o subcarpeta
    if (cwd.readFileAlloc(io, "../config.local.json", allocator, .unlimited)) |d| return d else |_| {}
    if (cwd.readFileAlloc(io, "../config.json", allocator, .unlimited)) |d| return d else |_| {}

    return null;
}

fn loadConfig(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(AppConfig) {
    if (readConfigData(allocator, io)) |data| {
        defer allocator.free(data);
        return try std.json.parseFromSlice(AppConfig, allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    std.debug.print("[Bridge-Zig] No se encontró config.json, usando valores por defecto\n", .{});
    const fallback = "{\"ollama_url\":\"http://127.0.0.1:11434\",\"default_model\":\"qwen2.5-coder:7b\",\"fallback_chain\":[],\"models\":[]}";
    return try std.json.parseFromSlice(AppConfig, allocator, fallback, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

// ============================================================================
// Utilidades JSON y Ejecución HTTP con Detección de Estado
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

fn executeHttpWithStatus(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !struct { body: []u8, http_code: u16 } {
    var full_argv: std.ArrayList([]const u8) = .empty;
    defer full_argv.deinit(allocator);

    try full_argv.appendSlice(allocator, argv);
    try full_argv.appendSlice(allocator, &[_][]const u8{ "-w", "\nHTTP_STATUS:%{http_code}" });

    const res = try std.process.run(allocator, io, .{
        .argv = full_argv.items,
    });
    defer allocator.free(res.stderr);

    const stdout = res.stdout;
    defer allocator.free(stdout);

    const marker = "\nHTTP_STATUS:";
    if (std.mem.lastIndexOf(u8, stdout, marker)) |idx| {
        const body_part = stdout[0..idx];
        const code_str = std.mem.trim(u8, stdout[idx + marker.len ..], " \r\n");
        const http_code = std.fmt.parseInt(u16, code_str, 10) catch 0;
        return .{
            .body = try allocator.dupe(u8, body_part),
            .http_code = http_code,
        };
    }

    return .{
        .body = try allocator.dupe(u8, stdout),
        .http_code = 0,
    };
}

// ============================================================================
// Consultas Núcleo a Modelos (Ollama y OpenAI) con Telemetría
// ============================================================================

fn callOllamaCore(allocator: std.mem.Allocator, io: std.Io, ollama_url: []const u8, model: []const u8, prompt: []const u8) !CallResult {
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

    const http_res = try executeHttpWithStatus(allocator, io, &argv);
    defer allocator.free(http_res.body);

    if (http_res.http_code != 200) {
        return CallResult{
            .text = try std.fmt.allocPrint(allocator, "Error HTTP {d} en Ollama ({s})", .{ http_res.http_code, http_res.body }),
            .http_status = http_res.http_code,
            .success = false,
            .model_name = model,
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, http_res.body, .{}) catch {
        return CallResult{
            .text = try allocator.dupe(u8, http_res.body),
            .http_status = http_res.http_code,
            .success = true,
            .model_name = model,
        };
    };
    defer parsed.deinit();

    var prompt_tok: u64 = 0;
    var comp_tok: u64 = 0;

    if (parsed.value == .object) {
        if (parsed.value.object.get("prompt_eval_count")) |pt| {
            if (pt == .integer and pt.integer > 0) prompt_tok = @intCast(pt.integer);
        }
        if (parsed.value.object.get("eval_count")) |ct| {
            if (ct == .integer and ct.integer > 0) comp_tok = @intCast(ct.integer);
        }
        if (parsed.value.object.get("response")) |resp| {
            if (resp == .string) {
                return CallResult{
                    .text = try allocator.dupe(u8, resp.string),
                    .prompt_tokens = prompt_tok,
                    .completion_tokens = comp_tok,
                    .http_status = 200,
                    .success = true,
                    .model_name = model,
                };
            }
        }
        if (parsed.value.object.get("error")) |err_val| {
            if (err_val == .string) {
                return CallResult{
                    .text = try std.fmt.allocPrint(allocator, "Error Ollama: {s}", .{err_val.string}),
                    .http_status = 500,
                    .success = false,
                    .model_name = model,
                };
            }
        }
    }

    return CallResult{
        .text = try allocator.dupe(u8, http_res.body),
        .http_status = 200,
        .success = true,
        .model_name = model,
    };
}

fn callOpenAICore(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8, model: []const u8, keys: []const []const u8, prompt: []const u8) !CallResult {
    if (keys.len == 0) {
        return CallResult{
            .text = try std.fmt.allocPrint(allocator, "Error: No se encontró ningún API Key/Token configurado para el modelo '{s}'.", .{model}),
            .http_status = 401,
            .success = false,
            .model_name = model,
        };
    }

    const escaped_prompt = try escapeJson(allocator, prompt);
    defer allocator.free(escaped_prompt);

    const payload = try std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}", .{ model, escaped_prompt });
    defer allocator.free(payload);

    var last_status: u16 = 500;
    var last_body: ?[]u8 = null;
    defer if (last_body) |b| allocator.free(b);

    for (keys, 0..) |key, k_idx| {
        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(allocator);

        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
        defer allocator.free(auth_header);

        try argv_list.appendSlice(allocator, &[_][]const u8{ "curl", "-s", "-X", "POST", endpoint, "-H", "Content-Type: application/json", "-H", auth_header, "-d", payload });

        const http_res = try executeHttpWithStatus(allocator, io, argv_list.items);
        if (last_body) |b| allocator.free(b);
        last_body = http_res.body;
        last_status = http_res.http_code;

        // Si falló por límite de cuota (429) o autorización (401) y hay más keys en el pool del mismo modelo:
        if ((http_res.http_code == 429 or http_res.http_code == 401) and k_idx + 1 < keys.len) {
            std.debug.print("[Bridge-Zig] ⚠️ Token #{d} de '{s}' devolvió HTTP {d}. Conmutando automáticamente al token #{d} del pool...\n", .{ k_idx + 1, model, http_res.http_code, k_idx + 2 });
            stat_fallbacks_count += 1;
            continue;
        }

        if (http_res.http_code != 200) {
            return CallResult{
                .text = try std.fmt.allocPrint(allocator, "HTTP {d} en Cloud ({s}): {s}", .{ http_res.http_code, model, http_res.body }),
                .http_status = http_res.http_code,
                .success = false,
                .model_name = model,
            };
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, http_res.body, .{}) catch {
            return CallResult{
                .text = try allocator.dupe(u8, http_res.body),
                .http_status = 200,
                .success = true,
                .model_name = model,
            };
        };
        defer parsed.deinit();

        var prompt_tok: u64 = 0;
        var comp_tok: u64 = 0;

        if (parsed.value == .object) {
            if (parsed.value.object.get("usage")) |usage| {
                if (usage == .object) {
                    if (usage.object.get("prompt_tokens")) |pt| {
                        if (pt == .integer and pt.integer > 0) prompt_tok = @intCast(pt.integer);
                    }
                    if (usage.object.get("completion_tokens")) |ct| {
                        if (ct == .integer and ct.integer > 0) comp_tok = @intCast(ct.integer);
                    }
                }
            }

            if (parsed.value.object.get("choices")) |choices| {
                if (choices == .array and choices.array.items.len > 0) {
                    const first = choices.array.items[0];
                    if (first == .object) {
                        if (first.object.get("message")) |msg| {
                            if (msg == .object) {
                                if (msg.object.get("content")) |content| {
                                    if (content == .string) {
                                        return CallResult{
                                            .text = try allocator.dupe(u8, content.string),
                                            .prompt_tokens = prompt_tok,
                                            .completion_tokens = comp_tok,
                                            .http_status = 200,
                                            .success = true,
                                            .model_name = model,
                                        };
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
                            return CallResult{
                                .text = try std.fmt.allocPrint(allocator, "Error API Cloud: {s}", .{msg.string}),
                                .http_status = 400,
                                .success = false,
                                .model_name = model,
                            };
                        }
                    }
                }
            }
        }

        return CallResult{
            .text = try allocator.dupe(u8, http_res.body),
            .http_status = 200,
            .success = true,
            .model_name = model,
        };
    }

    return CallResult{
        .text = try std.fmt.allocPrint(allocator, "HTTP {d} en Cloud ({s}): {s}", .{ last_status, model, if (last_body) |b| b else "Sin respuesta" }),
        .http_status = last_status,
        .success = false,
        .model_name = model,
    };
}

fn callModelById(allocator: std.mem.Allocator, io: std.Io, config: *const AppConfig, model_id: []const u8, prompt: []const u8) !CallResult {
    for (config.models) |m| {
        if (std.mem.eql(u8, m.id, model_id)) {
            if (std.mem.eql(u8, m.provider, "ollama")) {
                const url = m.endpoint orelse config.ollama_url;
                return try callOllamaCore(allocator, io, url, m.model, prompt);
            } else if (std.mem.eql(u8, m.provider, "openai")) {
                const endpoint = m.endpoint orelse return CallResult{
                    .text = try allocator.dupe(u8, "Modelo sin endpoint configurado."),
                    .http_status = 400,
                    .success = false,
                    .model_name = m.model,
                };

                var keys_list: std.ArrayList([]const u8) = .empty;
                defer keys_list.deinit(allocator);

                if (m.api_keys) |ks| {
                    for (ks) |k| {
                        const trimmed = std.mem.trim(u8, k, " \t\r\n");
                        if (trimmed.len > 0) try keys_list.append(allocator, trimmed);
                    }
                }
                if (m.api_key) |k| {
                    var it = std.mem.splitScalar(u8, k, ',');
                    while (it.next()) |part| {
                        const trimmed = std.mem.trim(u8, part, " \t\r\n");
                        if (trimmed.len > 0) try keys_list.append(allocator, trimmed);
                    }
                }
                if (m.api_key_env) |env_name| {
                    var env_name_z: [256]u8 = undefined;
                    if (env_name.len < env_name_z.len) {
                        @memcpy(env_name_z[0..env_name.len], env_name);
                        env_name_z[env_name.len] = 0;
                        if (getenv(env_name_z[0..env_name.len :0])) |val| {
                            const raw_val = std.mem.span(val);
                            var it = std.mem.splitScalar(u8, raw_val, ',');
                            while (it.next()) |part| {
                                const trimmed = std.mem.trim(u8, part, " \t\r\n");
                                if (trimmed.len > 0) try keys_list.append(allocator, trimmed);
                            }
                        }
                    }
                }

                return try callOpenAICore(allocator, io, endpoint, m.model, keys_list.items, prompt);
            }
        }
    }

    // Si no está registrado en models, llamada directa a Ollama con ese id como modelo
    return try callOllamaCore(allocator, io, config.ollama_url, model_id, prompt);
}

// ============================================================================
// Handlers de Herramientas MCP
// ============================================================================

fn handleAskOllama(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ![]u8 {
    const config_parsed = try loadConfig(allocator, io);
    defer config_parsed.deinit();

    const prompt_val = if (args == .object) args.object.get("prompt") else null;
    const prompt = if (prompt_val) |p| (if (p == .string) p.string else "") else "";

    if (prompt.len == 0) return try allocator.dupe(u8, "Error: Debes proporcionar un 'prompt'.");

    var model = config_parsed.value.default_model;
    if (args == .object) {
        if (args.object.get("model")) |m| {
            if (m == .string and m.string.len > 0) model = m.string;
        }
    }

    const res = try callOllamaCore(allocator, io, config_parsed.value.ollama_url, model, prompt);
    defer allocator.free(res.text);

    if (res.success) {
        stat_calls_count += 1;
        stat_prompt_tokens += res.prompt_tokens;
        stat_completion_tokens += res.completion_tokens;

        return try std.fmt.allocPrint(
            allocator,
            "{s}\n\n---\n📊 **Telemetría:** `Ollama ({s})` | Tokens: {d} (Entrada: {d}, Salida: {d})",
            .{ res.text, model, res.prompt_tokens + res.completion_tokens, res.prompt_tokens, res.completion_tokens },
        );
    } else {
        return try allocator.dupe(u8, res.text);
    }
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

    const res = try callModelById(allocator, io, &config_parsed.value, model_id, prompt);
    defer allocator.free(res.text);

    if (res.success) {
        stat_calls_count += 1;
        stat_prompt_tokens += res.prompt_tokens;
        stat_completion_tokens += res.completion_tokens;

        return try std.fmt.allocPrint(
            allocator,
            "{s}\n\n---\n📊 **Telemetría:** Modelo `{s}` | Tokens: {d} (Entrada: {d}, Salida: {d})",
            .{ res.text, res.model_name, res.prompt_tokens + res.completion_tokens, res.prompt_tokens, res.completion_tokens },
        );
    } else {
        return try allocator.dupe(u8, res.text);
    }
}

fn handleAskResilient(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ![]u8 {
    const config_parsed = try loadConfig(allocator, io);
    defer config_parsed.deinit();

    const prompt_val = if (args == .object) args.object.get("prompt") else null;
    const prompt = if (prompt_val) |p| (if (p == .string) p.string else "") else "";

    if (prompt.len == 0) return try allocator.dupe(u8, "Error: Debes proporcionar un 'prompt'.");

    const initial_model_val = if (args == .object) args.object.get("initial_model") else null;
    const initial_model = if (initial_model_val) |m| (if (m == .string and m.string.len > 0) m.string else null) else null;

    // Construir lista de candidatos
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(allocator);

    if (initial_model) |im| {
        try candidates.append(allocator, im);
    }

    for (config_parsed.value.fallback_chain) |fc| {
        if (initial_model == null or !std.mem.eql(u8, fc, initial_model.?)) {
            try candidates.append(allocator, fc);
        }
    }

    // Si la cadena está vacía, usar modelos disponibles por defecto
    if (candidates.items.len == 0) {
        for (config_parsed.value.models) |m| {
            try candidates.append(allocator, m.id);
        }
    }

    var history_log: std.ArrayList(u8) = .empty;
    defer history_log.deinit(allocator);

    for (candidates.items) |cand_id| {
        std.debug.print("[Bridge-Zig] Intentando modelo '{s}'...\n", .{cand_id});
        const res = callModelById(allocator, io, &config_parsed.value, cand_id, prompt) catch |err| CallResult{
            .text = try std.fmt.allocPrint(allocator, "Error interno: {any}", .{err}),
            .http_status = 500,
            .success = false,
            .model_name = cand_id,
        };
        defer allocator.free(res.text);

        if (res.success) {
            stat_calls_count += 1;
            stat_prompt_tokens += res.prompt_tokens;
            stat_completion_tokens += res.completion_tokens;

            const fallback_note = if (history_log.items.len > 0)
                try std.fmt.allocPrint(allocator, "\n🔄 *Conmutación automática (Fallback): {s}*✅ Exitoso en `{s}`", .{ history_log.items, cand_id })
            else
                try allocator.dupe(u8, "");
            defer allocator.free(fallback_note);

            return try std.fmt.allocPrint(
                allocator,
                "{s}\n\n---\n📊 **Telemetría:** Modelo `{s}` ({s}) | Tokens: {d} (Entrada: {d}, Salida: {d}){s}",
                .{ res.text, cand_id, res.model_name, res.prompt_tokens + res.completion_tokens, res.prompt_tokens, res.completion_tokens, fallback_note },
            );
        } else {
            stat_fallbacks_count += 1;
            std.debug.print("[Bridge-Zig] ⚠️ '{s}' falló (HTTP {d}). Pasando al siguiente modelo en cadena...\n", .{ cand_id, res.http_status });
            const log_entry = try std.fmt.allocPrint(allocator, "`{s}` (HTTP {d}) ➔ ", .{ cand_id, res.http_status });
            defer allocator.free(log_entry);
            try history_log.appendSlice(allocator, log_entry);
        }
    }

    return try std.fmt.allocPrint(
        allocator,
        "❌ **Error:** Todos los modelos en la cadena de fallback fallaron.\n\nHistorial de intentos:\n{s}(fin de cadena)",
        .{history_log.items},
    );
}

fn handleGetStats(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "📊 **Telemetría y Consumo Acumulado (Sesión Actual):**\n\n" ++
            "• **Total de Peticiones Procesadas:** {d}\n" ++
            "• **Conmutaciones Automáticas (Fallbacks):** {d}\n" ++
            "• **Tokens de Entrada (Prompt):** {d}\n" ++
            "• **Tokens de Salida (Generación):** {d}\n" ++
            "• **Total de Tokens Acumulados:** {d}\n\n" ++
            "💡 *Tip de Co-work:* Para tareas masivas o desatendidas, usa `ask_resilient`. Si un proveedor en la nube llega a su límite de cuota (Rate Limit 429), el puente conmuta automáticamente al siguiente sin parar el flujo.",
        .{
            stat_calls_count,
            stat_fallbacks_count,
            stat_prompt_tokens,
            stat_completion_tokens,
            stat_prompt_tokens + stat_completion_tokens,
        },
    );
}

fn handleListModels(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const config_parsed = try loadConfig(allocator, io);
    defer config_parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "🤖 **Modelos Registrados en config.json:**\n\n");
    const header = try std.fmt.allocPrint(allocator, "• **Ollama Local Predeterminado:** `{s}` (URL: {s})\n\n", .{ config_parsed.value.default_model, config_parsed.value.ollama_url });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    if (config_parsed.value.fallback_chain.len > 0) {
        try out.appendSlice(allocator, "🔄 **Cadena de Conmutación Automática (Fallback):**\n");
        for (config_parsed.value.fallback_chain, 0..) |fc, i| {
            const arrow = if (i + 1 < config_parsed.value.fallback_chain.len) " ➔ " else "\n\n";
            const piece = try std.fmt.allocPrint(allocator, "`{s}`{s}", .{ fc, arrow });
            defer allocator.free(piece);
            try out.appendSlice(allocator, piece);
        }
    }

    try out.appendSlice(allocator, "📋 **Catálogo de Modelos:**\n");
    for (config_parsed.value.models, 1..) |m, idx| {
        const item = try std.fmt.allocPrint(
            allocator,
            "{d}. ID: `{s}` | Nombre: **{s}**\n   - Proveedor: {s}\n   - Modelo API: `{s}`\n   - Endpoint: {s}\n\n",
            .{ idx, m.id, m.name, m.provider, m.model, m.endpoint orelse "(default)" },
        );
        defer allocator.free(item);
        try out.appendSlice(allocator, item);
    }

    return try out.toOwnedSlice(allocator);
}

fn handleAddModel(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ![]u8 {
    if (args != .object) return try allocator.dupe(u8, "Error: argumentos inválidos.");

    const id_val = args.object.get("id") orelse return try allocator.dupe(u8, "Falta 'id'");
    const name_val = args.object.get("name") orelse id_val;
    const provider_val = args.object.get("provider") orelse return try allocator.dupe(u8, "Falta 'provider' ('ollama' o 'openai')");
    const model_val = args.object.get("model") orelse return try allocator.dupe(u8, "Falta 'model'");
    const endpoint_val = args.object.get("endpoint");
    const env_val = args.object.get("api_key_env");
    const direct_key_val = args.object.get("api_key");

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
    if (direct_key_val) |dk| {
        if (dk == .string) try new_model_obj.put(allocator, "api_key", .{ .string = dk.string });
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
        \\{{"name":"ask_resilient","description":"Ejecuta peticiones con conmutación automática de modelos (Auto-Fallback). Si un proveedor falla o agota su límite de cuota (Rate Limit 429), conmuta automáticamente al siguiente hasta completarla.","inputSchema":{{"type":"object","properties":{{"prompt":{{"type":"string","description":"Instrucción o tarea a procesar."}},"initial_model":{{"type":"string","description":"Modelo inicial sugerido (opcional, ej: 'groq')."}}}},"required":["prompt"]}}}},
        \\{{"name":"ask_ollama","description":"Consulta un modelo local en Ollama (ej: qwen2.5-coder:7b, deepseek-r1:8b, llama3.2). Muestra tokens consumidos.","inputSchema":{{"type":"object","properties":{{"prompt":{{"type":"string","description":"Mensaje o pregunta para el modelo."}},"model":{{"type":"string","description":"Nombre del modelo de Ollama (opcional, usa el predeterminado si se omite)."}}}},"required":["prompt"]}}}},
        \\{{"name":"ask_model","description":"Consulta un modelo específico configurado en config.json por su ID (ej: 'groq', 'cerebras', 'gemini'). Muestra tokens consumidos.","inputSchema":{{"type":"object","properties":{{"model_id":{{"type":"string","description":"ID del modelo registrado."}},"prompt":{{"type":"string","description":"Mensaje o instrucción para el modelo."}}}},"required":["model_id","prompt"]}}}},
        \\{{"name":"get_stats","description":"Devuelve el consumo total acumulado de tokens (prompt, respuesta) y conmutaciones de fallback de la sesión.","inputSchema":{{"type":"object","properties":{{}}}}}},
        \\{{"name":"list_models","description":"Lista todos los modelos configurados en config.json y el orden de la cadena de fallback.","inputSchema":{{"type":"object","properties":{{}}}}}},
        \\{{"name":"add_model","description":"Agrega un nuevo modelo a config.json dinámicamente sin reiniciar ni recompilar.","inputSchema":{{"type":"object","properties":{{"id":{{"type":"string","description":"ID único del modelo (ej: 'mi-llama', 'groq-mixtral')."}},"name":{{"type":"string","description":"Nombre descriptivo."}},"provider":{{"type":"string","description":"'ollama' o 'openai'."}},"model":{{"type":"string","description":"Nombre real del modelo en la API."}},"endpoint":{{"type":"string","description":"URL del endpoint (opcional para Ollama, obligatoria para APIs OpenAI-compatibles)."}},"api_key_env":{{"type":"string","description":"Nombre de la variable de entorno con el API key (opcional)."}},"api_key":{{"type":"string","description":"API Key directa en config.json (opcional, alternativa a variable de entorno)."}}}},"required":["id","provider","model"]}}}}
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
                var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
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
                                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"antigravity-zig-bridge\",\"version\":\"2.0.0\"}}}}}}",
                                .{id_str},
                            );
                            defer allocator.free(resp);
                            sendResponse(resp);
                        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
                            // ACK
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

                                    if (std.mem.eql(u8, tool_name, "ask_resilient")) {
                                        result_text = handleAskResilient(allocator, io, args_val) catch |err| blk: {
                                            is_error = true;
                                            break :blk try std.fmt.allocPrint(allocator, "Error ejecutando ask_resilient: {any}", .{err});
                                        };
                                    } else if (std.mem.eql(u8, tool_name, "ask_ollama")) {
                                        result_text = handleAskOllama(allocator, io, args_val) catch |err| blk: {
                                            is_error = true;
                                            break :blk try std.fmt.allocPrint(allocator, "Error ejecutando ask_ollama: {any}", .{err});
                                        };
                                    } else if (std.mem.eql(u8, tool_name, "ask_model")) {
                                        result_text = handleAskModel(allocator, io, args_val) catch |err| blk: {
                                            is_error = true;
                                            break :blk try std.fmt.allocPrint(allocator, "Error ejecutando ask_model: {any}", .{err});
                                        };
                                    } else if (std.mem.eql(u8, tool_name, "get_stats")) {
                                        result_text = handleGetStats(allocator) catch |err| blk: {
                                            is_error = true;
                                            break :blk try std.fmt.allocPrint(allocator, "Error ejecutando get_stats: {any}", .{err});
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

            const rem_start = newline_idx + 1;
            const rem_len = len - rem_start;
            if (rem_len > 0) {
                std.mem.copyForwards(u8, buf[0..rem_len], buf[rem_start..len]);
            }
            len = rem_len;
        }
    }
}
