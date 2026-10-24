import Foundation

@main
struct AutorizacionAgentesChecks {
    static func main() throws {
        let archivos = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("nuvex-agentes-\(UUID().uuidString)", isDirectory: true)
        defer { try? archivos.removeItem(at: base) }
        let comando = "/Users/prueba/.local/bin/nuvex"
        let habilidad = AutorizacionAgentes.personalizarHabilidad(
            "Ejecuta ~/.local/bin/nuvex estado y ~/.local/bin/nuvex diagnostico.",
            comando: comando
        )
        precondition(!habilidad.contains(AutorizacionAgentes.comandoPlantilla))
        precondition(habilidad == "Ejecuta \(comando) estado y \(comando) diagnostico.")

        let codex = base.appendingPathComponent(".codex", isDirectory: true)
        try archivos.createDirectory(at: codex, withIntermediateDirectories: true)
        let codexApp = base.appendingPathComponent(
            "Library/Application Support/Parall/ChatGPT (X)/.codex", isDirectory: true
        )
        try archivos.createDirectory(at: codexApp, withIntermediateDirectories: true)
        let otraApp = base.appendingPathComponent(
            "Library/Application Support/Parall/Otra/.codex", isDirectory: true
        )
        try archivos.createDirectory(at: otraApp, withIntermediateDirectories: true)
        precondition(AutorizacionAgentes.raicesCodex(home: base) == [codex, codexApp],
                     "se prepara Codex CLI y el hogar aislado de Codex Desktop")
        precondition(AutorizacionAgentes.estadoCodex(raiz: codex, comando: comando) == .ausente)
        try AutorizacionAgentes.instalarCodex(raiz: codex, comando: comando)
        precondition(AutorizacionAgentes.estadoCodex(raiz: codex, comando: comando) == .instalada)
        let reglaCodex = codex.appendingPathComponent("rules/nuvex.rules")
        let permisosCodex = try archivos.attributesOfItem(atPath: reglaCodex.path)[.posixPermissions] as? Int
        precondition(permisosCodex == 0o600)
        let textoCodex = try String(contentsOf: reglaCodex, encoding: .utf8)
        precondition(textoCodex.contains("pattern = [\"\(comando)\"]"))
        if let codex = ProcessInfo.processInfo.environment["NUVEX_CODEX_BIN"],
           archivos.isExecutableFile(atPath: codex) {
            let proceso = Process()
            let salida = Pipe()
            proceso.executableURL = URL(fileURLWithPath: codex)
            proceso.arguments = ["execpolicy", "check", "--pretty", "--rules", reglaCodex.path,
                                  "--", comando, "estado", "--json"]
            proceso.standardOutput = salida
            proceso.standardError = salida
            try proceso.run()
            proceso.waitUntilExit()
            let texto = String(decoding: salida.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            precondition(proceso.terminationStatus == 0 && texto.contains("\"decision\": \"allow\""),
                         "Codex debe aceptar la regla generada: \(texto)")
        }
        try AutorizacionAgentes.quitarCodex(raiz: codex)
        precondition(!archivos.fileExists(atPath: reglaCodex.path))

        try Data("# regla ajena que cita: \(AutorizacionAgentes.marcaCodex)\n".utf8)
            .write(to: reglaCodex, options: .atomic)
        precondition(AutorizacionAgentes.estadoCodex(raiz: codex, comando: comando) == .ajena)
        do {
            try AutorizacionAgentes.instalarCodex(raiz: codex, comando: comando)
            preconditionFailure("no se debe reemplazar una regla ajena")
        } catch {}
        let reglaAjena = try String(contentsOf: reglaCodex, encoding: .utf8)
        precondition(reglaAjena == "# regla ajena que cita: \(AutorizacionAgentes.marcaCodex)\n")

        let claude = base.appendingPathComponent(".claude", isDirectory: true)
        try archivos.createDirectory(at: claude, withIntermediateDirectories: true)
        let ajustesClaude = claude.appendingPathComponent("settings.json")
        let inicial: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(git status)"]],
            "sandbox": ["network": ["allowedDomains": ["example.invalid"]]],
        ]
        try JSONSerialization.data(withJSONObject: inicial).write(to: ajustesClaude)
        try archivos.setAttributes([.posixPermissions: 0o640], ofItemAtPath: ajustesClaude.path)
        try AutorizacionAgentes.instalarClaude(raiz: claude, comando: comando)
        try AutorizacionAgentes.instalarClaude(raiz: claude, comando: comando)
        precondition(AutorizacionAgentes.estadoClaude(raiz: claude, comando: comando) == .instalada)
        let instalado = try JSONSerialization.jsonObject(with: Data(contentsOf: ajustesClaude)) as! [String: Any]
        let permitidas = (instalado["permissions"] as! [String: Any])["allow"] as! [String]
        let excluidas = (instalado["sandbox"] as! [String: Any])["excludedCommands"] as! [String]
        precondition(permitidas.filter { $0 == AutorizacionAgentes.reglaPermisoClaude(comando) }.count == 1)
        precondition(excluidas.filter { $0 == AutorizacionAgentes.reglaSandboxClaude(comando) }.count == 1)
        precondition(instalado["model"] as? String == "opus")
        let permisosClaude = try archivos.attributesOfItem(atPath: ajustesClaude.path)[.posixPermissions] as? Int
        precondition(permisosClaude == 0o640, "se conservan los permisos del archivo existente")
        if let claudeBin = ProcessInfo.processInfo.environment["NUVEX_CLAUDE_BIN"],
           archivos.isExecutableFile(atPath: claudeBin) {
            let proceso = Process()
            let salida = Pipe()
            proceso.executableURL = URL(fileURLWithPath: claudeBin)
            proceso.arguments = ["--settings", ajustesClaude.path, "--version"]
            proceso.standardOutput = salida
            proceso.standardError = salida
            try proceso.run()
            proceso.waitUntilExit()
            let texto = String(decoding: salida.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            precondition(proceso.terminationStatus == 0,
                         "Claude Code debe aceptar los ajustes generados: \(texto)")
        }

        try AutorizacionAgentes.quitarClaude(raiz: claude, comando: comando)
        precondition(AutorizacionAgentes.estadoClaude(raiz: claude, comando: comando) == .ausente)
        let revocado = try JSONSerialization.jsonObject(with: Data(contentsOf: ajustesClaude)) as! [String: Any]
        precondition(((revocado["permissions"] as! [String: Any])["allow"] as! [String]) == ["Bash(git status)"])
        precondition(((revocado["sandbox"] as! [String: Any])["network"] as! [String: Any])["allowedDomains"] as! [String]
                     == ["example.invalid"])

        try Data(#"{"permissions":[]}"#.utf8).write(to: ajustesClaude, options: .atomic)
        precondition(AutorizacionAgentes.estadoClaude(raiz: claude, comando: comando) == .ajena)
        do {
            try AutorizacionAgentes.instalarClaude(raiz: claude, comando: comando)
            preconditionFailure("no se debe reescribir una configuración inválida")
        } catch {}

        print("Agentes: reglas persistentes acotadas, reversibles y conservadoras comprobadas")
    }
}
