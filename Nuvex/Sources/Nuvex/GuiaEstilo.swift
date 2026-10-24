#if DEBUG
import AppKit
import SwiftUI

/// Referencia visual del sistema de diseño, solo en compilaciones de
/// depuración. `Nuvex --guia-estilo` la abre en una ventana, con el vidrio y
/// los estados interactivos reales, y `--captura` la exporta en claro y oscuro.
/// Lee los mismos tokens que la app: lo que se ve aquí es lo implementado.
/// Como las capturas, no crea el modelo: no lee conexiones ni el Llavero.
@MainActor
enum GuiaEstilo {
    static func ejecutar() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let ventana = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 860),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
        ventana.title = "Guía de estilo de Nuvex"
        ventana.contentViewController = NSHostingController(rootView: GuiaEstiloView())
        ventana.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: ventana,
                                               queue: .main) { _ in exit(0) }
        app.activate(ignoringOtherApps: true)
        ventana.makeKeyAndOrderFront(nil)
        app.run()
        exit(0)
    }
}

/// Medidas de la propia guía: una columna de lectura de 800 pt.
private enum Pagina {
    static let ancho: CGFloat = 880
    /// Ancho de los párrafos: unas 90 letras, cómodo de leer.
    static let parrafo: CGFloat = 600
    static let columnaToken: CGFloat = 168
}

struct GuiaEstiloView: View {
    /// Las capturas necesitan la altura completa, sin desplazamiento.
    var desplazable = true

    var body: some View {
        if desplazable {
            ScrollView { contenido }.frame(minWidth: Pagina.ancho, minHeight: 600).fondoVentana()
        } else {
            contenido.fondoVentana()
        }
    }

    private var contenido: some View {
        VStack(alignment: .leading, spacing: Espacio.seccion) {
            Portada()
            SeccionGuia(1, "Color", "Superficies grafito y niebla, bordes de un píxel y los colores de estado del sistema. Los valores se resuelven en esta apariencia.") {
                PaletaGuia()
            }
            SeccionGuia(2, "Texto y contraste", "Sobre vidrio, los estilos jerárquicos del sistema conservan la vibración. Sobre superficies opacas, tonos con el contraste medido aquí mismo.") {
                ContrasteGuia()
            }
            SeccionGuia(3, "Tipografía", "SF Pro con los estilos de texto de macOS: respetan el tamaño de texto de cada persona. La jerarquía la dan el tamaño y el peso, nunca el color.") {
                TipografiaGuia()
            }
            SeccionGuia(4, "Espaciado, radios y bordes", "Retícula de 2 pt. Radios continuos y concéntricos; trazos de un píxel.") {
                GeometriaGuia()
            }
            SeccionGuia(5, "Profundidad", "Cuatro planos, cada uno con su superficie, borde y sombra. En claro eleva la sombra; en oscuro, la luminosidad y una línea de luz.") {
                ProfundidadGuia()
            }
            SeccionGuia(6, "Liquid Glass", "Para lo que navega o flota sobre el contenido: la ventana del panel, la barra lateral, las barras de acciones, los menús y los botones. El contenido nunca es de vidrio.") {
                VidrioGuia()
            }
            SeccionGuia(7, "Botones", "Cápsulas del sistema. Una sola acción con tinte por vista; lo destructivo, en rojo legible y con confirmación.") {
                BotonesGuia()
            }
            SeccionGuia(8, "Campos y controles", "Controles del sistema en formularios. El campo destacado, solo para un dato protagonista.") {
                ControlesGuia()
            }
            SeccionGuia(9, "Interacción", "Respuesta inmediata y breve. En la ventana, pasa el puntero y pulsa: los estados son reales.") {
                InteraccionGuia()
            }
            SeccionGuia(10, "Estados", "El color nunca va solo: siempre acompaña a un símbolo y a un texto.") {
                EstadosGuia()
            }
            SeccionGuia(11, "Panel de la barra de menús", "La ventana del panel ya es vidrio del sistema. Por eso los círculos son opacos: no se apila vidrio sobre vidrio.") {
                FilasGuia()
            }
            SeccionGuia(12, "Iconografía", "SF Symbols en relleno y peso semibold. Los iconos de Ajustes, sobre cuadrados de color con la curvatura de macOS.") {
                IconografiaGuia()
            }
        }
        .padding(.horizontal, Espacio.pantalla)
        .padding(.top, Espacio.pantalla + Espacio.xxl)
        .padding(.bottom, Espacio.seccion)
        .frame(width: Pagina.ancho, alignment: .leading)
    }
}

// MARK: - Estructura

private struct Portada: View {
    @Environment(\.colorScheme) private var esquema

    private let principios: [(String, String, String)] = [
        ("text.alignleft", "Claridad primero", "La jerarquía la dan la tipografía y el espacio, no los contenedores."),
        ("square.on.square", "Vidrio con propósito", "Solo en lo que navega o flota. El contenido es opaco y legible."),
        ("square.stack.3d.up", "Profundidad natural", "Cuatro planos. Sombra amplia en claro; luz en oscuro."),
        ("circle.lefthalf.filled", "Calma", "Un solo tinte por vista. El color señala estado, nunca decora."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.bloque) {
            HStack(spacing: Espacio.m) {
                LogoNuvex(lado: Tamano.iconoLista + Espacio.xs)
                Text("Nuvex").font(Tipo.encabezado)
                Text("Sistema de diseño").foregroundStyle(Paleta.textoSecundario)
            }
            VStack(alignment: .leading, spacing: Espacio.l) {
                Text("Guía de estilo").font(Tipo.portada)
                Text("Sobria, precisa y nativa de macOS. Liquid Glass para lo que navega y flota; superficies opacas y una tipografía clara para el contenido.")
                    .font(Tipo.entradilla)
                    .foregroundStyle(Paleta.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Pagina.parrafo, alignment: .leading)
                HStack(spacing: Espacio.m) {
                    Pastilla(texto: esquema == .dark ? "Apariencia oscura" : "Apariencia clara")
                    Pastilla(texto: "macOS 14 o posterior")
                    Pastilla(texto: "Tokens: Diseno.swift")
                }
            }
            Grid(alignment: .topLeading, horizontalSpacing: Espacio.xxl, verticalSpacing: 0) {
                GridRow {
                    ForEach(principios, id: \.1) { simbolo, titulo, detalle in
                        VStack(alignment: .leading, spacing: Espacio.s) {
                            Image(systemName: simbolo)
                                .font(Tipo.encabezado)
                                .foregroundStyle(Paleta.textoSecundario)
                                .frame(height: Tamano.iconoLista, alignment: .leading)
                            Text(titulo).font(Tipo.cuerpoEnfasis)
                            Text(detalle).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, Espacio.xs)
        }
    }
}

private struct SeccionGuia<Contenido: View>: View {
    let numero: Int
    let titulo: String
    let detalle: String
    let contenido: Contenido

    init(_ numero: Int, _ titulo: String, _ detalle: String, @ViewBuilder contenido: () -> Contenido) {
        self.numero = numero
        self.titulo = titulo
        self.detalle = detalle
        self.contenido = contenido()
    }

    // Sin tarjeta ni separador: el número, el título y el espacio entre
    // secciones bastan para delimitarlas.
    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.bloque) {
            VStack(alignment: .leading, spacing: Espacio.s) {
                Text(String(format: "%02d", numero))
                    .font(Tipo.monoNota)
                    .foregroundStyle(Paleta.textoTerciario)
                Text(titulo).font(Tipo.pantalla)
                Text(detalle).foregroundStyle(Paleta.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Pagina.parrafo, alignment: .leading)
            }
            contenido
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Título de un grupo dentro de una sección.
private struct Rotulo: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }
    var body: some View {
        Text(texto).font(Tipo.encabezado)
    }
}

/// Nombre de un token: monoespaciado y secundario, como metadatos.
private struct Token: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }
    var body: some View {
        Text(texto).font(Tipo.monoNota).foregroundStyle(Paleta.textoSecundario).textSelection(.enabled)
    }
}

/// Damero bajo los colores translúcidos para que se aprecie su opacidad.
private struct Damero: View {
    var body: some View {
        Canvas { contexto, tamano in
            let lado: CGFloat = 6
            for fila in 0..<Int(tamano.height / lado) + 1 {
                for columna in 0..<Int(tamano.width / lado) + 1 where (fila + columna).isMultiple(of: 2) {
                    contexto.fill(Path(CGRect(x: CGFloat(columna) * lado, y: CGFloat(fila) * lado,
                                              width: lado, height: lado)), with: .color(Paleta.relleno))
                }
            }
        }
        .background(Paleta.superficie)
    }
}

// MARK: - Color

private struct PaletaGuia: View {
    private enum Muestra {
        case plano(Elevacion)
        case relleno
        case texto
    }

    private let grupos: [(String, [(String, Color, Muestra)])] = [
        // De abajo arriba; el plano flotante, al final, para que su sombra
        // amplia no caiga sobre otra muestra.
        ("Superficies", [("fondo", Paleta.fondo, .plano(.base)),
                         ("fondoFormulario", Paleta.fondoFormulario, .relleno),
                         ("campo", Paleta.campo, .relleno),
                         ("superficie", Paleta.superficie, .plano(.contenido)),
                         ("superficieElevada", Paleta.superficieElevada, .plano(.elevado)),
                         ("superficieFlotante", Paleta.superficieFlotante, .plano(.flotante))]),
        ("Rellenos y bordes", [("relleno", Paleta.relleno, .relleno), ("rellenoIntenso", Paleta.rellenoIntenso, .relleno),
                               ("borde", Paleta.borde, .relleno), ("bordeFuerte", Paleta.bordeFuerte, .relleno),
                               ("bordeLuz", Paleta.bordeLuz, .relleno), ("brillo", Paleta.brillo, .relleno)]),
        ("Acento y estados", [("acento", Paleta.acento, .relleno), ("exito", Paleta.exito, .relleno),
                              ("aviso", Paleta.aviso, .relleno), ("error", Paleta.error, .relleno),
                              ("precaucion", Paleta.precaucion, .relleno), ("info", Paleta.info, .relleno)]),
        ("Texto", [("textoSecundario", Paleta.textoSecundario, .texto), ("textoTerciario", Paleta.textoTerciario, .texto),
                   ("exitoTexto", Paleta.exitoTexto, .texto), ("avisoTexto", Paleta.avisoTexto, .texto),
                   ("errorTexto", Paleta.errorTexto, .texto), ("infoTexto", Paleta.infoTexto, .texto)]),
        ("Marca", [("marcaCian", Paleta.marcaCian, .relleno), ("marcaAzul", Paleta.marcaAzul, .relleno),
                   ("marcaIndigo", Paleta.marcaIndigo, .relleno), ("grafito", Paleta.grafito, .relleno),
                   ("neutro", Paleta.neutro, .relleno)]),
    ]

    private let columnas = Array(repeating: GridItem(.flexible(), spacing: Espacio.l, alignment: .top), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.bloque) {
            ForEach(grupos, id: \.0) { grupo in
                VStack(alignment: .leading, spacing: Espacio.l) {
                    Rotulo(grupo.0)
                    LazyVGrid(columns: columnas, alignment: .leading, spacing: Espacio.xl) {
                        ForEach(Array(grupo.1.enumerated()), id: \.element.0) { indice, elemento in
                            MuestraColor(nombre: elemento.0, color: elemento.1) { muestraVisual(elemento.1, elemento.2) }
                                .zIndex(Double(grupo.1.count - indice))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func muestraVisual(_ color: Color, _ muestra: Muestra) -> some View {
        let forma = RoundedRectangle.nuvex(Radio.m)
        switch muestra {
        case .plano(let elevacion):
            Color.clear.superficie(elevacion, radio: Radio.m)
                .overlay {
                    if elevacion == .base { forma.strokeBorder(Paleta.borde, lineWidth: Borde.fino) }
                }
        case .relleno:
            ZStack {
                Damero()
                color
            }
            .clipShape(forma)
            .overlay(forma.strokeBorder(Paleta.borde, lineWidth: Borde.fino))
        case .texto:
            Text("Aa")
                .font(Tipo.pantalla)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .superficie(.contenido, radio: Radio.m)
        }
    }
}

private struct MuestraColor<Visual: View>: View {
    let nombre: String
    let color: Color
    let visual: Visual
    @Environment(\.self) private var entorno

    init(nombre: String, color: Color, @ViewBuilder visual: () -> Visual) {
        self.nombre = nombre
        self.color = color
        self.visual = visual()
    }

    private var hex: String {
        let r = color.resolve(in: entorno)
        let valor = [r.red, r.green, r.blue].map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
        return r.opacity < 0.995 ? "#\(valor) \(Int((r.opacity * 100).rounded()))%" : "#\(valor)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.m) {
            visual.frame(height: 56)
            VStack(alignment: .leading, spacing: Espacio.xxs) {
                Text(nombre).font(Tipo.apoyo.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
                Token(hex)
            }
        }
    }
}

// MARK: - Contraste

/// Contraste WCAG calculado con los colores resueltos en esta apariencia.
private struct ContrasteGuia: View {
    @Environment(\.self) private var entorno

    private let pares: [(String, Color, String, Color)] = [
        ("textoSecundario", Paleta.textoSecundario, "fondo", Paleta.fondo),
        ("textoSecundario", Paleta.textoSecundario, "superficie", Paleta.superficie),
        ("textoSecundario", Paleta.textoSecundario, "superficieFlotante", Paleta.superficieFlotante),
        ("textoTerciario", Paleta.textoTerciario, "fondo", Paleta.fondo),
        ("exitoTexto", Paleta.exitoTexto, "superficie", Paleta.superficie),
        ("avisoTexto", Paleta.avisoTexto, "superficie", Paleta.superficie),
        ("errorTexto", Paleta.errorTexto, "superficie", Paleta.superficie),
        ("infoTexto", Paleta.infoTexto, "superficie", Paleta.superficie),
        ("aviso", Paleta.aviso, "superficie", Paleta.superficie),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Espacio.xxl, verticalSpacing: Espacio.m) {
            GridRow {
                Text("Muestra"); Text("Texto sobre superficie"); Text("Contraste"); Text("Uso permitido")
            }
            .font(Tipo.nota.weight(.medium))
            .foregroundStyle(Paleta.textoSecundario)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(pares.indices, id: \.self) { i in
                let (texto, colorTexto, fondo, colorFondo) = pares[i]
                let ratio = Self.contraste(colorTexto.resolve(in: entorno), colorFondo.resolve(in: entorno))
                GridRow {
                    Text("Conectada · 1 h 12 min")
                        .foregroundStyle(colorTexto)
                        .padding(.horizontal, Espacio.m)
                        .padding(.vertical, Espacio.xs)
                        .background(RoundedRectangle.nuvex(Radio.s).fill(colorFondo))
                        .overlay(RoundedRectangle.nuvex(Radio.s).strokeBorder(Paleta.borde, lineWidth: Borde.fino))
                    Text("\(texto) / \(fondo)").font(Tipo.monoNota)
                    Text(String(format: "%.1f:1", ratio))
                        .font(Tipo.cuerpoEnfasis).monospacedDigit()
                    veredicto(ratio)
                }
            }
        }
    }

    @ViewBuilder
    private func veredicto(_ ratio: Double) -> some View {
        if ratio >= 4.5 {
            Pastilla(texto: "Texto · AA", color: Paleta.exito)
        } else if ratio >= 3 {
            Pastilla(texto: "Rótulos e interfaz · 3:1", color: Paleta.info)
        } else {
            Pastilla(texto: "Solo símbolos", color: Paleta.neutro)
        }
    }

    private static func luminancia(_ c: Color.Resolved) -> Double {
        func lineal(_ v: Float) -> Double {
            let x = Double(v)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lineal(c.red) + 0.7152 * lineal(c.green) + 0.0722 * lineal(c.blue)
    }

    static func contraste(_ a: Color.Resolved, _ b: Color.Resolved) -> Double {
        let (la, lb) = (luminancia(a), luminancia(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

// MARK: - Tipografía

private struct TipografiaGuia: View {
    private let estilos: [(String, Font, NSFont.TextStyle, String, String)] = [
        ("portada", Tipo.portada, .largeTitle, "Guía de estilo", "Una por documento largo"),
        ("pantalla", Tipo.pantalla, .title1, "Te damos la bienvenida", "Ventana propia, sección"),
        ("entradilla", Tipo.entradilla, .title3, "Conecta tus VPN desde la barra de menús.", "Presenta una pantalla"),
        ("titulo", Tipo.titulo, .title2, "Oficina central", "Cabecera de un detalle"),
        ("encabezado", Tipo.encabezado, .headline, "Código de verificación", "Grupos, filas destacadas"),
        ("cuerpoEnfasis", Tipo.cuerpoEnfasis, .body, "Añade tu servidor y usuario", "Nombre de una fila"),
        ("cuerpo", Tipo.cuerpo, .body, "Conecta tus VPN Fortinet desde la barra de menús.", "Texto corriente"),
        ("apoyo", Tipo.apoyo, .callout, "La contraseña se guarda en el Llavero.", "Explicaciones, pies"),
        ("nota", Tipo.nota, .caption1, "Conectada · 1 h 12 min", "Estado bajo un nombre"),
        ("etiqueta", Tipo.etiqueta, .caption2, "Sin guardar", "Pastillas"),
        ("mono", Tipo.mono, .body, "vpn.empresa.com:443", "Servidores, rutas, IP"),
        ("codigo", Tipo.codigo, .title2, "482 913", "Códigos de verificación"),
    ]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Espacio.xxl, verticalSpacing: Espacio.xl) {
            ForEach(estilos, id: \.0) { nombre, fuente, estilo, ejemplo, uso in
                GridRow {
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text("Tipo.\(nombre)").font(Tipo.monoNota)
                        Text("\(Int(NSFont.preferredFont(forTextStyle: estilo).pointSize)) pt · \(peso(nombre))")
                            .font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                    }
                    .frame(width: Pagina.columnaToken, alignment: .leading)
                    Text(ejemplo).font(fuente).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(uso).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                        .frame(width: 200, alignment: .leading)
                }
            }
        }
    }

    private func peso(_ nombre: String) -> String {
        switch nombre {
        case "portada", "pantalla": return "Bold"
        case "titulo", "encabezado", "etiqueta", "codigo": return "Semibold"
        case "cuerpoEnfasis": return "Medium"
        default: return "Regular"
        }
    }
}

// MARK: - Geometría

private struct GeometriaGuia: View {
    private let espacios: [(String, CGFloat, String)] = [
        ("xxs", Espacio.xxs, "Título y subtítulo"), ("xs", Espacio.xs, "Icono y texto compacto"),
        ("s", Espacio.s, "Dentro de una fila"), ("m", Espacio.m, "Entre controles"),
        ("l", Espacio.l, "Icono y nombre de fila"), ("xl", Espacio.xl, "Entre grupos"),
        ("xxl", Espacio.xxl, "Márgenes de barra"), ("xxxl", Espacio.xxxl, "Márgenes de hoja"),
        ("bloque", Espacio.bloque, "Entre bloques"), ("pantalla", Espacio.pantalla, "Margen de pantalla"),
        ("seccion", Espacio.seccion, "Entre secciones largas"),
    ]
    private let radios: [(String, CGFloat)] = [
        ("xs", Radio.xs), ("s", Radio.s), ("m", Radio.m), ("l", Radio.l), ("xl", Radio.xl), ("xxl", Radio.xxl),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.bloque) {
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Espacio")
                Grid(alignment: .leading, horizontalSpacing: Espacio.xl, verticalSpacing: Espacio.s) {
                    ForEach(espacios, id: \.0) { nombre, valor, uso in
                        GridRow {
                            Text("Espacio.\(nombre)").font(Tipo.monoNota)
                                .frame(width: Pagina.columnaToken - Espacio.xxl, alignment: .leading)
                            Text("\(Int(valor))").font(Tipo.monoNota).foregroundStyle(Paleta.textoSecundario)
                                .frame(width: Espacio.xxxl, alignment: .trailing)
                            // A tamaño real: el ancho de la barra es el valor.
                            Capsule().fill(Paleta.acento.opacity(0.7))
                                .frame(width: valor, height: Espacio.s)
                                .frame(width: Espacio.seccion, alignment: .leading)
                            Text(uso).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Radio")
                HStack(alignment: .bottom, spacing: Espacio.xl) {
                    ForEach(radios, id: \.0) { nombre, valor in
                        VStack(alignment: .leading, spacing: Espacio.s) {
                            // Cuadradas: con radios grandes sobre un lado corto, el
                            // trazo continuo deja marcas en los lados.
                            Color.clear.superficie(.contenido, radio: valor).frame(width: 72, height: 72)
                            Token("Radio.\(nombre) · \(Int(valor))")
                        }
                    }
                    VStack(alignment: .leading, spacing: Espacio.s) {
                        Capsule(style: .circular).fill(Paleta.superficie)
                            .overlay(Capsule(style: .circular).stroke(Paleta.borde, lineWidth: Borde.fino))
                            .frame(width: 84, height: 28)
                            .frame(height: 72, alignment: .bottom)
                        Token("Capsule")
                    }
                }
            }
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Concentricidad")
                HStack(spacing: Espacio.bloque) {
                    // Exterior xl (20) con margen s (6): el interior usa 20 − 6 = 14 (l).
                    Color.clear.superficie(.contenido, radio: Radio.xl)
                        .overlay(
                            RoundedRectangle.nuvex(Radio.l).fill(Paleta.acento.opacity(0.14))
                                .overlay(RoundedRectangle.nuvex(Radio.l).strokeBorder(Paleta.acento.opacity(0.35), lineWidth: Borde.fino))
                                .padding(Espacio.s)
                        )
                        .frame(width: 200, height: 72)
                    VStack(alignment: .leading, spacing: Espacio.xs) {
                        Text("Radio interior = radio exterior − margen").font(Tipo.cuerpoEnfasis)
                        Text("Aquí: xl (20) − s (6) = l (14). Los trazos son de un píxel (Borde.fino); el foco, de 3 pt.")
                            .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                    }
                }
            }
        }
    }
}

// MARK: - Profundidad y vidrio

private struct ProfundidadGuia: View {
    var body: some View {
        HStack(alignment: .top, spacing: Espacio.xxl) {
            ForEach(Elevacion.allCases, id: \.self) { plano in
                VStack(alignment: .leading, spacing: Espacio.l) {
                    Color.clear.superficie(plano)
                        .overlay {
                            if plano == .base {
                                RoundedRectangle.nuvex(Radio.l)
                                    .strokeBorder(Paleta.bordeFuerte, style: StrokeStyle(lineWidth: Borde.fino, dash: [4, 3]))
                            }
                        }
                        .frame(height: 96)
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text(titulo(plano)).font(Tipo.cuerpoEnfasis)
                        Text(detalle(plano)).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                            .fixedSize(horizontal: false, vertical: true)
                        Token(".superficie(.\(plano))").padding(.top, Espacio.xs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // La sombra amplia de un plano no debe caer sobre el vecino:
                // los primeros se dibujan encima.
                .zIndex(Double(Elevacion.allCases.count - (Elevacion.allCases.firstIndex(of: plano) ?? 0)))
            }
        }
    }

    private func titulo(_ plano: Elevacion) -> String {
        switch plano {
        case .base: return "0 · Fondo"
        case .contenido: return "1 · Contenido"
        case .elevado: return "2 · Elevado"
        case .flotante: return "3 · Flotante"
        }
    }

    private func detalle(_ plano: Elevacion) -> String {
        switch plano {
        case .base: return "La ventana. Sin borde ni sombra."
        case .contenido: return "Secciones y muestras. Borde de un píxel."
        case .elevado: return "Una unidad sobre el contenido. Sombra sutil."
        case .flotante: return "Popovers y menús sin vidrio. Sombra amplia."
        }
    }
}

private struct VidrioGuia: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.l) {
            ZStack(alignment: .top) {
                fondo
                VStack(spacing: 0) {
                    // Barra de herramientas: un grupo de vidrio por función.
                    HStack(spacing: Espacio.m) {
                        HStack(spacing: Espacio.l) {
                            ForEach(["sidebar.left", "plus", "slider.horizontal.3"], id: \.self) { simbolo in
                                Image(systemName: simbolo).font(Tipo.encabezado)
                            }
                        }
                        .padding(.horizontal, Espacio.l)
                        .frame(height: Tamano.circuloEstado + Espacio.xs)
                        .vidrio(.regular)
                        Spacer()
                        Text("Conectar")
                            .font(Tipo.cuerpoEnfasis).foregroundStyle(.white)
                            .padding(.horizontal, Espacio.xl)
                            .frame(height: Tamano.circuloEstado + Espacio.xs)
                            .vidrio(.regular, tinte: Paleta.acento, respaldo: Paleta.acento)
                    }
                    .grupoVidrio()
                    .padding(Espacio.l)
                    Spacer()
                    HStack(spacing: Espacio.xxl) {
                        muestra("sutil", .sutil)
                        muestra("regular", .regular)
                        muestra("flotante", .flotante)
                    }
                    .grupoVidrio()
                    .padding(.bottom, Espacio.xxl)
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle.nuvex(Radio.xl))
            Text("Arriba, una barra de herramientas sobre contenido que se desplaza: un grupo de vidrio por función y una sola acción con tinte. Abajo, los tres niveles de `.vidrio` para controles flotantes a medida.")
                .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Pagina.parrafo, alignment: .leading)
        }
    }

    /// Contenido de muestra bajo el vidrio: colores suaves de la marca y filas
    /// de texto simuladas, para que se aprecien la refracción y la legibilidad.
    private var fondo: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Paleta.marcaCian.opacity(0.45), Paleta.marcaAzul.opacity(0.35),
                                    Paleta.marcaIndigo.opacity(0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: Espacio.l) {
                ForEach(0..<7, id: \.self) { i in
                    HStack(spacing: Espacio.l) {
                        Circle().fill(Paleta.conexiones[i].opacity(0.85)).frame(width: 20, height: 20)
                        Capsule().fill(.primary.opacity(0.22)).frame(width: CGFloat(140 + (i * 53) % 200), height: 7)
                        Spacer()
                        Capsule().fill(.primary.opacity(0.12)).frame(width: 60, height: 7)
                    }
                }
            }
            .padding(.horizontal, Espacio.bloque)
            .padding(.top, Espacio.l)
        }
    }

    private func muestra(_ nombre: String, _ nivel: NivelVidrio) -> some View {
        Text(nombre)
            .font(Tipo.cuerpoEnfasis)
            .padding(.horizontal, Espacio.xl)
            .frame(height: Tamano.circuloEstado + Espacio.xs)
            .vidrio(nivel, en: Capsule())
    }
}

// MARK: - Botones y controles

private struct BotonesGuia: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Espacio.xl, verticalSpacing: Espacio.l) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(["Pequeño", "Normal", "Grande", "Desactivado", "Cargando"], id: \.self) {
                    Text($0).font(Tipo.nota.weight(.medium)).foregroundStyle(Paleta.textoSecundario)
                }
            }
            fila("principal", .principal)
            fila("secundario", .secundario)
            GridRow {
                Token(".destructivo")
                Button("Eliminar…", role: .destructive) {}.estiloBoton(.destructivo).controlSize(.small)
                Button("Eliminar conexión…", role: .destructive) {}.estiloBoton(.destructivo)
                Button("Olvidar cuenta…", role: .destructive) {}.estiloBoton(.destructivo).controlSize(.large)
                Button("Eliminar…", role: .destructive) {}.estiloBoton(.destructivo).disabled(true)
                Color.clear.frame(width: 1, height: 1)
            }
            GridRow {
                Token(".link")
                Button("Mostrar registro") {}.buttonStyle(.link).controlSize(.small)
                Button("Ahora no") {}.buttonStyle(.link)
                Button("Ver versiones") {}.buttonStyle(.link).controlSize(.large)
                Button("Ahora no") {}.buttonStyle(.link).disabled(true)
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private func fila(_ nombre: String, _ estilo: EstiloBoton) -> some View {
        GridRow {
            Token(".\(nombre)")
            Button("Reconectar") {}.estiloBoton(estilo).controlSize(.small)
            Button("Guardar") {}.estiloBoton(estilo)
            Button("Conectar ahora") {}.estiloBoton(estilo).controlSize(.large)
            Button("Guardar") {}.estiloBoton(estilo).disabled(true)
            Button {} label: {
                HStack(spacing: Espacio.s) { ProgressView().controlSize(.mini); Text("Guardando…") }
            }
            .estiloBoton(estilo).disabled(true)
        }
    }
}

private struct ControlesGuia: View {
    @State private var texto = "vpn.empresa.com:443"
    @State private var interruptor = true
    @State private var opcion = "system"
    @State private var segmento = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.bloque) {
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Campo destacado")
                HStack(spacing: Espacio.xl) {
                    campo("Reposo", enfocado: false, error: false)
                    campo("Foco", enfocado: true, error: false)
                    campo("Error", enfocado: false, error: true)
                }
            }
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Formulario del sistema con barra de acciones")
                HStack(alignment: .top, spacing: Espacio.bloque) {
                    Form {
                        TextField("Servidor", text: $texto, prompt: Text("vpn.empresa.com:443"))
                        Toggle("Instalar las rutas de esta VPN", isOn: $interruptor)
                        Picker("Confianza TLS", selection: $opcion) {
                            Text("Certificados del sistema").tag("system")
                            Text("Huella SHA-256").tag("sha256")
                        }
                        Picker("Esperar el correo", selection: $segmento) {
                            Text("60 s").tag(0); Text("120 s").tag(1); Text("180 s").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }
                    .formularioNuvex()
                    .barraAcciones {
                        HStack(spacing: Espacio.m) {
                            HStack(spacing: Espacio.s) {
                                Indicador(color: Paleta.aviso)
                                Text("Cambios sin guardar").foregroundStyle(Paleta.textoSecundario)
                            }
                            .font(Tipo.apoyo)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Revertir") {}.estiloBoton(.secundario)
                            Button("Guardar") {}.estiloBoton(.principal)
                        }
                    }
                    .frame(width: 520, height: 280)
                    .clipShape(RoundedRectangle.nuvex(Radio.l))
                    .overlay(RoundedRectangle.nuvex(Radio.l).strokeBorder(Paleta.borde, lineWidth: Borde.fino))
                    Text("Secciones, filas, interruptores y menús son los del sistema: se adaptan a cada versión de macOS y a sus ajustes de accesibilidad. La barra de acciones sigue la columna del formulario (704 pt como máximo) y el contenido se funde bajo ella.")
                        .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func campo(_ nombre: String, enfocado: Bool, error: Bool) -> some View {
        VStack(alignment: .leading, spacing: Espacio.s) {
            Text("482913")
                .font(Tipo.codigo)
                .frame(maxWidth: .infinity)
                .campoDestacado(enfocado: enfocado, error: error)
            Text(nombre).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
        }
    }
}

// MARK: - Interacción

private struct InteraccionGuia: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.bloque) {
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Estados de una fila")
                HStack(spacing: Espacio.l) {
                    estado("Reposo", relleno: .clear)
                    estado("Puntero", relleno: Paleta.relleno)
                    estado("Pulsada", relleno: Paleta.rellenoIntenso)
                    estado("Desactivada", relleno: .clear, opacidad: 0.45)
                }
                Text("El foco de teclado lo dibuja el sistema con «Acceso total con teclado». Los cambios usan `Movimiento.rapida` (0,18 s).")
                    .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
            }
            HStack(alignment: .top, spacing: Espacio.bloque) {
                columna("EstiloFila", "Relleno al pasar el puntero; más intenso al pulsar.") {
                    VStack(spacing: 0) {
                        fila("Laboratorio", activa: true)
                        fila("Sucursal Sur", activa: false)
                    }
                }
                columna("EstiloPresion", "Se hunde al 92 %; con «Reducir movimiento», solo se oscurece.") {
                    Button {} label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: Tamano.simboloCirculo, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: Tamano.circuloEstado, height: Tamano.circuloEstado)
                            .background(Circle().fill(Paleta.acento))
                    }
                    .buttonStyle(EstiloPresion())
                    .frame(height: 2 * Tamano.filaPanel, alignment: .topLeading)
                }
                columna("BotonCopiar", "Confirma con una marca durante 1,2 s.") {
                    HStack(spacing: Espacio.xs) {
                        Text("10.0.0.7").font(Tipo.mono)
                        BotonCopiar(texto: "10.0.0.7", etiqueta: "Copiar IP")
                    }
                    .frame(height: 2 * Tamano.filaPanel, alignment: .topLeading)
                }
            }
        }
    }

    private func columna<Demo: View>(_ nombre: String, _ detalle: String,
                                     @ViewBuilder demo: () -> Demo) -> some View {
        VStack(alignment: .leading, spacing: Espacio.m) {
            Token(nombre)
            demo()
            Text(detalle).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func contenidoFila(_ nombre: String) -> some View {
        HStack(spacing: Espacio.l) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: Tamano.simboloCirculo, weight: .semibold))
                .frame(width: Tamano.circuloEstado, height: Tamano.circuloEstado)
                .background(Circle().fill(Paleta.rellenoIntenso))
            Text(nombre).font(Tipo.cuerpoEnfasis).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Espacio.m)
        .padding(.vertical, Espacio.s)
    }

    private func estado(_ nombre: String, relleno: Color, opacidad: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: Espacio.s) {
            contenidoFila("Laboratorio")
                .background(RoundedRectangle.nuvex(Radio.m).fill(relleno))
                .opacity(opacidad)
            Text(nombre).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                .padding(.leading, Espacio.m)
        }
        .frame(maxWidth: .infinity)
    }

    private func fila(_ nombre: String, activa: Bool) -> some View {
        Button {} label: {
            contenidoFila(nombre).contentShape(Rectangle())
        }
        .buttonStyle(EstiloFila())
        .disabled(!activa)
    }
}

// MARK: - Estados

private struct EstadosGuia: View {
    private let avisos: [(String, Color, String)] = [
        ("Conexiones exportadas", Paleta.exito, "checkmark.circle.fill"),
        ("El ayudante de red necesita tu autorización.", Paleta.aviso, "exclamationmark.triangle.fill"),
        ("No se pudo leer el estado.", Paleta.error, "xmark.octagon.fill"),
        ("Nuvex 3.3.0 está disponible.", Paleta.acento, "arrow.down.circle.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.bloque) {
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Ciclo de una conexión")
                HStack(alignment: .top, spacing: Espacio.xl) {
                    ciclo("Desconectada", "lock.open.fill", fondo: Paleta.rellenoIntenso, simbolo: .primary)
                    ciclo("Conectando", "lock.open.fill", fondo: Paleta.rellenoIntenso, simbolo: .primary, cargando: true)
                    ciclo("Conectada", "lock.fill", fondo: Paleta.acento, simbolo: .white)
                    ciclo("Atención", "exclamationmark.triangle.fill", fondo: Paleta.aviso.opacity(0.16), simbolo: Paleta.aviso)
                    ciclo("Error", "exclamationmark.triangle.fill", fondo: Paleta.error.opacity(0.16), simbolo: Paleta.error)
                }
            }
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Pastillas e indicadores")
                HStack(spacing: Espacio.m) {
                    Pastilla(texto: "Conectada", color: Paleta.exito, conIndicador: true)
                    Pastilla(texto: "Sin guardar", color: Paleta.aviso, conIndicador: true)
                    Pastilla(texto: "Beta", color: Paleta.aviso)
                    Pastilla(texto: "Importante", color: Paleta.error)
                    Pastilla(texto: "Oculta")
                    Spacer().frame(width: Espacio.xl)
                    Indicador(color: Paleta.exito); Indicador(color: Paleta.aviso); Indicador(color: Paleta.error)
                }
            }
            HStack(alignment: .top, spacing: Espacio.bloque) {
                VStack(alignment: .leading, spacing: Espacio.l) {
                    Rotulo("Avisos en línea")
                    VStack(alignment: .leading, spacing: Espacio.m) {
                        ForEach(avisos, id: \.0) { texto, color, simbolo in
                            Label {
                                Text(texto).foregroundStyle(color == Paleta.error ? Paleta.errorTexto : Paleta.textoSecundario)
                            } icon: {
                                Image(systemName: simbolo).foregroundStyle(color)
                            }
                            .font(Tipo.apoyo)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: Espacio.l) {
                    Rotulo("Estado vacío")
                    EstadoVacio("No hay conexiones visibles",
                                detalle: "Activa «Mostrar en la barra de menús» en Ajustes.", simbolo: "eye.slash") {
                        Button("Abrir Ajustes…") {}.estiloBoton(.secundario)
                    }
                    .padding(.vertical, Espacio.xl)
                    .superficie(.contenido)
                }
                .frame(width: Tamano.panel)
            }
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Progreso")
                HStack(spacing: Espacio.xxl) {
                    ProgressView(value: 0.42).frame(width: 220)
                    ProgressView().controlSize(.small)
                    HStack(spacing: Espacio.s) {
                        ForEach(0..<3, id: \.self) { nivel in
                            Capsule().fill(nivel < 2 ? Paleta.precaucion : Paleta.rellenoIntenso)
                                .frame(width: 48, height: Espacio.xs)
                        }
                    }
                }
            }
        }
    }

    private func ciclo(_ nombre: String, _ icono: String, fondo: Color, simbolo: Color,
                       cargando: Bool = false) -> some View {
        VStack(spacing: Espacio.s) {
            Image(systemName: icono)
                .font(.system(size: Tamano.simboloCirculo, weight: .semibold))
                .foregroundStyle(simbolo)
                .frame(width: Tamano.circuloEstado, height: Tamano.circuloEstado)
                .background(Circle().fill(fondo))
                .overlay {
                    if cargando {
                        Circle().trim(from: 0, to: 0.3)
                            .stroke(Paleta.acento, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .padding(-3)
                            .rotationEffect(.degrees(-60))
                    }
                }
            Text(nombre).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
        }
        .frame(width: 88)
    }
}

private struct FilasGuia: View {
    private func estado(_ id: String, _ nombre: String, conectada: Bool = false) -> VPNStatus {
        VPNStatus(id: id, name: nombre, connected: conectada, pid: conectada ? 1 : 0, ip: conectada ? "10.0.0.7" : "",
                  iface: conectada ? "ppp0" : "", networks: [], enabled: true, configured: true, helperReady: true,
                  inicio: conectada ? Date().addingTimeInterval(-72 * 60) : nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Espacio.bloque) {
            VStack(spacing: 0) {
                fila(estado("a", "Oficina central", conectada: true), .conectada)
                fila(estado("b", "Prepa · Sedes"), .conectando, desde: Date().addingTimeInterval(-14))
                fila(estado("c", "Cliente Norte"), .error(Fallo.interpretar("Could not authenticate to gateway")))
                fila(estado("d", "Laboratorio"), .desconectada, atajo: 4)
            }
            .padding(Espacio.s)
            .frame(width: Tamano.panel)
            .vidrio(.flotante, en: RoundedRectangle.nuvex(Radio.xl))
            VStack(alignment: .leading, spacing: Espacio.l) {
                regla("El círculo es el control", "Neutro y opaco desconectado; acento al conectar; el color de su estado, al 16 %, cuando requiere atención.")
                regla("El texto explica", "Bajo el nombre, el estado en `Tipo.nota`. En rojo o naranja legibles solo si pide una acción.")
                regla("Una acción por fila", "Botón secundario pequeño a la derecha. El atajo ⌘1–9 aparece solo en reposo.")
                regla("Movimiento", "El anillo gira mientras conecta; con «Reducir movimiento» queda fijo.")
            }
        }
    }

    private func regla(_ titulo: String, _ detalle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Espacio.xxs) {
            Text(titulo).font(Tipo.cuerpoEnfasis)
            Text(detalle).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fila(_ vpn: VPNStatus, _ estado: EstadoUI, desde: Date? = nil, atajo: Int? = nil) -> some View {
        FilaVPN(vpn: vpn, estado: estado, passwordStatus: .saved, caidaEn: nil, conectandoDesde: desde,
                atajo: atajo, bloqueada: false, alAlternar: {}, alConfigurar: {}, alDescartar: {})
    }
}

// MARK: - Iconografía

private struct IconografiaGuia: View {
    private let simbolos = [
        "lock.fill", "lock.open.fill", "key.fill", "exclamationmark.triangle.fill", "xmark.octagon.fill",
        "checkmark.circle.fill", "shield.lefthalf.filled", "slider.horizontal.3", "arrow.down.circle.fill",
        "sparkles", "envelope.fill", "terminal.fill", "doc.on.doc", "chevron.right",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.bloque) {
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Iconos de Ajustes")
                HStack(alignment: .bottom, spacing: Espacio.xxl) {
                    tamano("Lista · 22", Tamano.iconoLista) {
                        HStack(spacing: Espacio.s) {
                            IconoCuadrado(simbolo: "gearshape.fill", color: Paleta.neutro)
                            IconoCuadrado(simbolo: "shield.lefthalf.filled", color: Paleta.iconoAyudante)
                            IconoCuadrado(simbolo: "terminal.fill", color: Paleta.grafito)
                            IconoCuadrado(simbolo: "envelope.fill", color: Paleta.iconoCorreo)
                        }
                    }
                    tamano("Cabecera · 40", Tamano.iconoCabecera) {
                        IconoCuadrado(simbolo: "lock.fill", color: Paleta.conexiones[9], lado: Tamano.iconoCabecera)
                    }
                    tamano("Destacado · 52", Tamano.iconoDestacado) {
                        IconoCuadrado(simbolo: "ellipsis.message.fill", color: Paleta.acento, lado: Tamano.iconoDestacado)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Tonos de conexión")
                HStack(spacing: Espacio.s) {
                    ForEach(Paleta.conexiones.indices, id: \.self) { i in
                        IconoCuadrado(simbolo: "lock.fill", color: Paleta.conexiones[i])
                    }
                }
                Text("Cada conexión conserva su tono, elegido a partir de su identificador.")
                    .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
            }
            VStack(alignment: .leading, spacing: Espacio.l) {
                Rotulo("Símbolos SF")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Espacio.l), count: 7),
                          alignment: .leading, spacing: Espacio.xl) {
                    ForEach(simbolos, id: \.self) { simbolo in
                        VStack(spacing: Espacio.s) {
                            Image(systemName: simbolo).font(Tipo.titulo).frame(height: Tamano.iconoLista + Espacio.xs)
                            Text(simbolo).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func tamano<Icono: View>(_ nombre: String, _ lado: CGFloat, @ViewBuilder icono: () -> Icono) -> some View {
        VStack(alignment: .leading, spacing: Espacio.s) {
            icono()
            Token(nombre)
        }
    }
}
#endif
