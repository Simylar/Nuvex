import SwiftUI

/// La misma configuración de servidor en el alta y en Ajustes. Ningún modo
/// relaja la verificación del certificado; se conserva la selección existente.
struct OpcionesServidor: View {
    @Binding var perfil: VPNProfile
    @State private var expandida = false

    private var personalizadas: Bool {
        perfil.trust != "system" || !perfil.realm.isEmpty || !perfil.manageRoutes || !perfil.manageDNS
    }

    var body: some View {
        Section {
            DisclosureGroup(personalizadas ? "Opciones del servidor · Personalizadas" : "Opciones del servidor", isExpanded: $expandida) {
                Picker("Certificado del servidor", selection: confianza) {
                    Text("Verificar automáticamente").tag("system")
                    Text("Certificado incluido (Prepa)").tag("bundle")
                    Text("Huella verificada (SHA-256)").tag("sha256")
                }
                if perfil.trust.hasPrefix("sha256:") {
                    TextField("Huella", text: huella, prompt: Text("64 caracteres hexadecimales"))
                        .font(Tipo.mono)
                    if !Validacion.huellaValida(perfil.trust) {
                        Text("Introduce la huella completa que te dio tu organización.")
                            .font(Tipo.apoyo).foregroundStyle(Paleta.avisoTexto)
                    }
                }
                Text(descripcionCertificado)
                    .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Grupo de acceso (realm)", text: $perfil.realm, prompt: Text("Opcional"))
                Toggle("Acceder a las redes de esta VPN", isOn: $perfil.manageRoutes)
                Toggle("Resolver direcciones con esta VPN", isOn: $perfil.manageDNS)
                Text("Estas opciones controlan las rutas y el DNS. Cámbialas solo si tu organización te lo indica o si varias VPN interfieren entre sí.")
                    .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("La configuración automática sirve para la mayoría de los servidores. Abre estas opciones si tu organización te dio un certificado o un grupo de acceso.")
                .foregroundStyle(Paleta.textoSecundario)
        }
        .onAppear { expandida = personalizadas }
    }

    private var descripcionCertificado: String {
        switch perfil.trust {
        case "system": return "Nuvex comprueba la identidad del servidor con los certificados de confianza de macOS."
        case "bundle": return "Usa el certificado incluido solo si tu organización confirma que corresponde a su servidor."
        default: return "Confirma esta huella con tu organización. Nuvex solo aceptará ese certificado."
        }
    }

    private var confianza: Binding<String> {
        Binding(get: { perfil.trust.hasPrefix("sha256:") ? "sha256" : perfil.trust },
                set: { perfil.trust = $0 == "sha256" ? "sha256:" : $0 })
    }

    private var huella: Binding<String> {
        Binding(get: { String(perfil.trust.dropFirst(7)) },
                set: { perfil.trust = "sha256:" + $0.filter { "0123456789abcdefABCDEF".contains($0) }.lowercased() })
    }
}
