import AppKit
import SwiftUI

// Sistema de diseño de Nuvex: la única fuente de colores, tipografía,
// espaciado, radios, materiales, sombras y movimiento de la interfaz. Cada
// valor está documentado en STYLE_GUIDE.md; una pantalla nueva no debería
// necesitar números ni colores sueltos.

@MainActor
enum Diseno {
    /// Las capturas dibujan las vistas fuera de pantalla, donde el vidrio del
    /// sistema no se compone; ahí se usa el material de respaldo.
    static var vidrioDelSistema = true
}

// MARK: - Color

extension Color {
    /// Color sRGB a partir de su valor hexadecimal (0xRRGGBB).
    init(hex: UInt32, opacidad: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacidad)
    }

    /// Color que se resuelve con la apariencia de la vista. Con «Aumentar
    /// contraste», la opacidad se multiplica por `refuerzo` para que bordes y
    /// rellenos sigan distinguiéndose.
    init(claro: UInt32, oscuro: UInt32, alfaClaro: Double = 1, alfaOscuro: Double = 1, refuerzo: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { apariencia in
            let estilos: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                 .accessibilityHighContrastDarkAqua]
            let estilo = apariencia.bestMatch(from: estilos) ?? .aqua
            let esOscuro = estilo == .darkAqua || estilo == .accessibilityHighContrastDarkAqua
            let contraste = estilo == .accessibilityHighContrastAqua || estilo == .accessibilityHighContrastDarkAqua
            let hex = esOscuro ? oscuro : claro
            let alfa = min(1, (esOscuro ? alfaOscuro : alfaClaro) * (contraste ? refuerzo : 1))
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alfa)
        })
    }
}

/// Paleta semántica. Sobre vidrio, el texto usa los estilos jerárquicos del
/// sistema (`.primary`, `.secondary`) para conservar la vibración; sobre
/// superficies opacas, los tonos de texto de aquí, con más contraste.
enum Paleta {
    // Marca: los tonos del logotipo. Solo para la marca, nunca para estados.
    static let marcaCian = Color(hex: 0x35C5FA)
    static let marcaAzul = Color(hex: 0x5278F7)
    static let marcaIndigo = Color(hex: 0x7650EC)

    /// Acento interactivo: el del sistema, para respetar la preferencia de cada persona.
    static let acento = Color.accentColor

    // Superficies: grafito en oscuro, niebla en claro. Nunca negro puro. En
    // claro la profundidad la dan las sombras; en oscuro, la luminosidad.
    static let fondo = Color(claro: 0xF5F5F7, oscuro: 0x16171A)
    /// Fondo de los formularios agrupados: en claro, el de las ventanas de
    /// macOS (sus secciones ya contrastan con él); en oscuro, grafito.
    static let fondoFormulario = Color(nsColor: NSColor(name: nil) { apariencia in
        let oscuro = apariencia.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return oscuro ? NSColor(srgbRed: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255, alpha: 1)
                      : .windowBackgroundColor
    })
    // Cada plano de la escala de `Elevacion` tiene su superficie. En oscuro
    // cada paso sube unos 9 puntos de luminosidad; en claro todas son blancas
    // y las separa la sombra.
    static let superficie = Color(claro: 0xFFFFFF, oscuro: 0x1F2023)
    static let superficieElevada = Color(claro: 0xFFFFFF, oscuro: 0x28292D)
    /// Respaldo opaco de lo que flota (popovers, «Reducir transparencia»).
    static let superficieFlotante = Color(claro: 0xFFFFFF, oscuro: 0x313236)
    /// Fondo del campo destacado: blanco en claro, como los campos de macOS.
    static let campo = Color(claro: 0xFFFFFF, oscuro: 0xFFFFFF, alfaClaro: 1, alfaOscuro: 0.06)
    /// Relleno de controles, filas al pasar el puntero y fichas.
    static let relleno = Color(claro: 0x000000, oscuro: 0xFFFFFF, alfaClaro: 0.05, alfaOscuro: 0.07, refuerzo: 1.8)
    /// Relleno al pulsar o seleccionar.
    static let rellenoIntenso = Color(claro: 0x000000, oscuro: 0xFFFFFF, alfaClaro: 0.09, alfaOscuro: 0.12, refuerzo: 1.6)

    // Bordes: trazos finos y semitransparentes.
    static let borde = Color(claro: 0x000000, oscuro: 0xFFFFFF, alfaClaro: 0.08, alfaOscuro: 0.09, refuerzo: 2.5)
    static let bordeFuerte = Color(claro: 0x000000, oscuro: 0xFFFFFF, alfaClaro: 0.14, alfaOscuro: 0.16, refuerzo: 2)
    /// Reflejo del borde superior de los materiales: la luz cae desde arriba.
    static let brillo = Color(claro: 0xFFFFFF, oscuro: 0xFFFFFF, alfaClaro: 0.70, alfaOscuro: 0.18)
    /// Borde superior de una superficie elevada. En oscuro, una línea de luz
    /// la separa del fondo; en claro coincide con `borde` y la eleva la sombra.
    static let bordeLuz = Color(claro: 0x000000, oscuro: 0xFFFFFF, alfaClaro: 0.08, alfaOscuro: 0.14, refuerzo: 2)

    // Texto sobre superficies opacas. `textoSecundario` supera 4,5:1 sobre
    // `fondo`, `superficie` y las secciones de formulario en ambas apariencias.
    static let textoSecundario = Color(claro: 0x6E6E73, oscuro: 0xA1A1A6)
    /// Solo para lo que repite información visible: atajos, rótulos. Supera
    /// 3:1 (contraste de elementos de interfaz) sobre todas las superficies.
    static let textoTerciario = Color(claro: 0x838388, oscuro: 0x808085)

    // Estados: colores del sistema, que macOS ajusta en claro, oscuro y alto contraste.
    static let exito = Color.green
    static let aviso = Color.orange
    static let error = Color.red
    static let precaucion = Color.yellow
    static let info = Color.blue

    // Texto con color de estado: las variantes de alto contraste de Apple, que
    // se leen sobre blanco y sobre grafito. Los símbolos usan el color base.
    static let exitoTexto = Color(claro: 0x1E7B34, oscuro: 0x30DB5B)
    static let avisoTexto = Color(claro: 0xB25000, oscuro: 0xFFB340)
    static let errorTexto = Color(claro: 0xD70015, oscuro: 0xFF6961)
    static let infoTexto = Color(claro: 0x0040DD, oscuro: 0x409CFF)

    /// Tono legible para el texto de un color de estado.
    static func texto(_ color: Color) -> Color {
        switch color {
        case exito: return exitoTexto
        case aviso: return avisoTexto
        case error: return errorTexto
        case info: return infoTexto
        case neutro: return textoSecundario
        default: return color
        }
    }

    // Iconos de Ajustes: cada página conserva su tono.
    static let neutro = Color.gray
    static let grafito = Color(claro: 0x3A3B40, oscuro: 0x4A4B50)
    static let iconoAyudante = Color.indigo
    static let iconoCorreo = Color.red

    /// Tonos que identifican cada conexión. Se eligen por su id, así que una
    /// conexión conserva su color.
    static let conexiones: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .green, .cyan, .mint, marcaIndigo]
}

// MARK: - Tipografía

/// Estilos de texto del sistema (SF Pro), para que respeten el tamaño de
/// texto de macOS. Ningún tamaño de letra se escribe a mano.
enum Tipo {
    /// Portada de un documento largo (la guía de estilo). Una por página.
    static let portada = Font.largeTitle.weight(.bold)
    /// Título de una pantalla completa: bienvenida, novedades.
    static let pantalla = Font.title.weight(.bold)
    /// Entradilla bajo el título de una pantalla: una o dos frases que la
    /// presentan. Siempre en `textoSecundario`.
    static let entradilla = Font.title3
    /// Título de una tarjeta o de la cabecera de un detalle.
    static let titulo = Font.title2.weight(.semibold)
    static let encabezado = Font.headline
    static let cuerpo = Font.body
    static let cuerpoEnfasis = Font.body.weight(.medium)
    static let apoyo = Font.callout
    static let nota = Font.caption
    static let etiqueta = Font.caption2.weight(.semibold)
    static let mono = Font.body.monospaced()
    static let monoNota = Font.caption.monospaced()
    /// Códigos de verificación: grandes, monoespaciados y con cifras tabulares.
    static let codigo = Font.system(.title2, design: .monospaced).weight(.semibold)
    /// Símbolo de un estado vacío, que escala con el texto.
    static let simboloVacio = Font.title2
}

// MARK: - Espaciado, tamaños, radios y bordes

/// Escala de espaciado sobre una retícula de 2 pt.
enum Espacio {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 24
    static let bloque: CGFloat = 32
    static let pantalla: CGFloat = 40
    /// Entre secciones de una página larga: sustituye al separador.
    static let seccion: CGFloat = 64
}

/// Medidas fijas de componentes.
enum Tamano {
    static let panel: CGFloat = 320
    /// Ventana dedicada al código: admite pantallas estrechas y contenido
    /// ampliado sin crecer fuera del área visible.
    static let codigoAnchoIdeal: CGFloat = 360
    static let codigoAnchoMinimo: CGFloat = 300
    static let codigoAltoIdeal: CGFloat = 420
    static let codigoAltoMinimo: CGFloat = 280
    static let codigoAltoMaximo: CGFloat = 560
    /// Ancho máximo de las secciones de un `Form` agrupado en macOS 27
    /// (medido): a partir de ahí se centran. Lo que acompaña al formulario,
    /// como la barra de acciones, usa la misma columna.
    static let columnaFormulario: CGFloat = 704
    static let circuloEstado: CGFloat = 28
    static let iconoLista: CGFloat = 22
    static let iconoCabecera: CGFloat = 40
    static let iconoDestacado: CGFloat = 52
    static let logoTarjeta: CGFloat = 56
    static let logoPantalla: CGFloat = 72
    static let indicador: CGFloat = 7
    /// Punto de una pastilla: un píxel menor que el indicador suelto.
    static let puntoPastilla: CGFloat = 6
    /// Alto mínimo de una pastilla: una línea de `Tipo.etiqueta` con aire.
    static let pastilla: CGFloat = 18
    /// Área de un botón de solo icono sin borde (copiar).
    static let botonIcono: CGFloat = 18
    /// Alto de una fila del panel de la barra de menús.
    static let filaPanel: CGFloat = 40
    // Símbolos SF dibujados a tamaño fijo dentro de una forma.
    static let simboloPequeno: CGFloat = 10
    static let simboloCirculo: CGFloat = 12
    static let simboloDestacado: CGFloat = 44
}

/// Radios de esquina, siempre continuos. Un elemento dentro de otro usa el
/// radio exterior menos el margen que los separa, para que sean concéntricos.
enum Radio {
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 10
    static let l: CGFloat = 14
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 26

    /// Esquina de un icono cuadrado, en la proporción de los iconos de macOS.
    static func icono(_ lado: CGFloat) -> CGFloat { lado * 0.2237 }
}

extension RoundedRectangle {
    /// Rectángulo continuo con uno de los radios del sistema.
    static func nuvex(_ radio: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radio, style: .continuous)
    }
}

/// Grosores de trazo.
enum Borde {
    /// Un píxel en pantallas Retina.
    static let fino: CGFloat = 0.5
    static let regular: CGFloat = 1
    static let foco: CGFloat = 3
}

// MARK: - Sombras

enum Sombra {
    /// Separa una tarjeta del fondo.
    case sutil
    /// Popovers y elementos destacados.
    case media
    /// Barras y controles que flotan sobre el contenido.
    case flotante
}

private struct ModificadorSombra: ViewModifier {
    let sombra: Sombra
    @Environment(\.colorScheme) private var esquema

    // Dos capas, como la luz real: una de contacto, corta y nítida, que
    // asienta el borde, y una ambiental amplia y muy tenue que da la altura.
    // Cuanto más alto el plano, más se desplaza y difumina la ambiental.
    func body(content: Content) -> some View {
        // El oscuro necesita más opacidad: la sombra se ve contra grafito.
        let o = esquema == .dark ? 3.0 : 1.0
        switch sombra {
        case .sutil:
            content
                .shadow(color: .black.opacity(0.05 * o), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(0.05 * o), radius: 10, y: 3)
        case .media:
            content
                .shadow(color: .black.opacity(0.05 * o), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(0.08 * o), radius: 18, y: 6)
        case .flotante:
            content
                .shadow(color: .black.opacity(0.06 * o), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.10 * o), radius: 28, y: 12)
        }
    }
}

extension View {
    func sombra(_ sombra: Sombra) -> some View { modifier(ModificadorSombra(sombra: sombra)) }
}

// MARK: - Materiales Liquid Glass

/// Niveles de vidrio. Se reservan para navegación, controles y elementos
/// flotantes; el contenido va sobre superficies opacas.
enum NivelVidrio {
    /// Agrupa controles sobre otra superficie, sin elevarlos.
    case sutil
    /// Controles y barras.
    case regular
    /// Capas que flotan sobre contenido que se desplaza por debajo.
    case flotante
}

private struct Vidrio<Forma: Shape>: ViewModifier {
    let nivel: NivelVidrio
    let forma: Forma
    let tinte: Color?
    let interactivo: Bool
    let respaldo: Color?
    @Environment(\.accessibilityReduceTransparency) private var reducirTransparencia

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), Diseno.vidrioDelSistema {
            // Liquid Glass del sistema: refracción, reflejos y adaptación al fondo.
            content
                .glassEffect(Glass.regular.tint(tinte).interactive(interactivo), in: forma)
                .modifier(SombraSegunNivel(nivel: nivel))
        } else {
            content
                .background {
                    if let respaldo {
                        forma.fill(respaldo)
                    } else if reducirTransparencia {
                        forma.fill(nivel == .flotante ? Paleta.superficieFlotante : Paleta.superficieElevada)
                    } else {
                        forma.fill(material)
                        if let tinte { forma.fill(tinte.opacity(0.18)) }
                    }
                }
                .overlay {
                    // Borde iluminado: el reflejo arriba se funde con el contorno.
                    forma.stroke(LinearGradient(colors: [Paleta.brillo, Paleta.borde, Paleta.borde],
                                                startPoint: .top, endPoint: .bottom),
                                 lineWidth: Borde.fino)
                }
                .modifier(SombraSegunNivel(nivel: nivel))
        }
    }

    private var material: Material {
        switch nivel {
        case .sutil: return .ultraThinMaterial
        case .regular: return .thinMaterial
        case .flotante: return .regularMaterial
        }
    }
}

private struct SombraSegunNivel: ViewModifier {
    let nivel: NivelVidrio
    func body(content: Content) -> some View {
        switch nivel {
        case .sutil: content
        case .regular: content.sombra(.sutil)
        case .flotante: content.sombra(.flotante)
        }
    }
}

extension View {
    /// Superficie Liquid Glass. En macOS 26 o posterior usa el material del
    /// sistema; en versiones anteriores, un material translúcido con borde
    /// iluminado. Con «Reducir transparencia» se vuelve opaca. `respaldo`
    /// sustituye al material antes de macOS 26 cuando el tinte debe ser sólido
    /// (un control activo con su símbolo en blanco).
    func vidrio(_ nivel: NivelVidrio = .regular, en forma: some Shape = Capsule(),
                tinte: Color? = nil, interactivo: Bool = false, respaldo: Color? = nil) -> some View {
        modifier(Vidrio(nivel: nivel, forma: forma, tinte: tinte, interactivo: interactivo, respaldo: respaldo))
    }

    /// Agrupa varios elementos de vidrio para que se fundan al acercarse.
    @ViewBuilder
    func grupoVidrio(espaciado: CGFloat = Espacio.m) -> some View {
        if #available(macOS 26.0, *), Diseno.vidrioDelSistema {
            GlassEffectContainer(spacing: espaciado) { self }
        } else {
            self
        }
    }
}

// MARK: - Superficies

/// Escala de profundidad: cada plano define a la vez su superficie, su borde
/// y su sombra, para que nunca se combinen por separado. Los planos opacos
/// son para contenido; lo que flota sobre contenido que se desplaza usa vidrio
/// (`.vidrio(.flotante)`) y `flotante` solo como respaldo opaco.
enum Elevacion: CaseIterable {
    /// Plano 0: el fondo de la ventana. Sin borde ni sombra.
    case base
    /// Plano 1: contenido agrupado (secciones de formulario, muestras). Sin
    /// sombra: lo separa el cambio de superficie.
    case contenido
    /// Plano 2: un elemento que se lee como unidad sobre el contenido.
    case elevado
    /// Plano 3: popovers, menús y paneles a medida sin vidrio.
    case flotante

    var relleno: Color {
        switch self {
        case .base: return Paleta.fondo
        case .contenido: return Paleta.superficie
        case .elevado: return Paleta.superficieElevada
        case .flotante: return Paleta.superficieFlotante
        }
    }

    var sombra: Sombra? {
        switch self {
        case .base, .contenido: return nil
        case .elevado: return .sutil
        case .flotante: return .flotante
        }
    }
}

private struct ModificadorSuperficie: ViewModifier {
    let elevacion: Elevacion
    let radio: CGFloat

    func body(content: Content) -> some View {
        content.background {
            let forma = RoundedRectangle.nuvex(radio)
            forma.fill(elevacion.relleno)
                .overlay {
                    switch elevacion {
                    case .base: EmptyView()
                    // Trazo centrado y no `strokeBorder`: con radios grandes,
                    // la forma interior continua deja muescas en los lados.
                    case .contenido: forma.stroke(Paleta.borde, lineWidth: Borde.fino)
                    case .elevado, .flotante:
                        // Línea de luz arriba que se funde con el contorno: en
                        // oscuro separa el plano; en claro coincide con el borde.
                        forma.stroke(LinearGradient(colors: [Paleta.bordeLuz, Paleta.borde],
                                                    startPoint: .top, endPoint: .center),
                                     lineWidth: Borde.fino)
                    }
                }
                .modifier(SombraOpcional(sombra: elevacion.sombra))
        }
    }
}

extension View {
    /// Superficie opaca de uno de los planos de `Elevacion`. Uso excepcional:
    /// solo cuando el límite tiene significado (una muestra, un resumen que se
    /// lee como unidad). Las secciones, listas y formularios no son tarjetas.
    func superficie(_ elevacion: Elevacion = .elevado, radio: CGFloat = Radio.l) -> some View {
        modifier(ModificadorSuperficie(elevacion: elevacion, radio: radio))
    }

    /// Formulario agrupado del sistema sobre el fondo de Nuvex.
    func formularioNuvex() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Paleta.fondoFormulario)
    }

    /// Barra de acciones al pie de un contenido desplazable. En macOS 26 o
    /// posterior es una barra del sistema con efecto de borde: el contenido se
    /// desvanece bajo ella y los botones de vidrio no se apilan sobre otro
    /// vidrio. Antes, una barra con material y separador.
    @ViewBuilder
    func barraAcciones(@ViewBuilder _ contenido: () -> some View) -> some View {
        if #available(macOS 26.0, *), Diseno.vidrioDelSistema {
            safeAreaBar(edge: .bottom, spacing: 0) {
                contenido()
                    .frame(maxWidth: Tamano.columnaFormulario)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Espacio.xxl)
                    .padding(.vertical, Espacio.l)
            }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    contenido()
                        .frame(maxWidth: Tamano.columnaFormulario)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Espacio.xxl)
                        .padding(.vertical, Espacio.m + Espacio.xxs)
                }
                .background(.bar)
            }
        }
    }

    /// Fondo de una ventana propia de Nuvex.
    func fondoVentana() -> some View {
        background(Paleta.fondo.ignoresSafeArea())
    }
}

private struct SombraOpcional: ViewModifier {
    let sombra: Sombra?
    func body(content: Content) -> some View {
        if let sombra { content.sombra(sombra) } else { content }
    }
}

// MARK: - Botones

enum EstiloBoton {
    /// La acción principal de una pantalla. Una sola por vista.
    case principal
    /// Acciones secundarias y de fila.
    case secundario
    /// Elimina u olvida datos. El botón con borde del sistema (el mismo que
    /// sus vecinos en un formulario) con el texto en rojo legible; nunca un
    /// relleno rojo. Debe llevar `role: .destructive` y pedir confirmación.
    case destructivo
}

extension View {
    /// Botón en forma de cápsula. En macOS 26 o posterior es Liquid Glass;
    /// antes, el botón con borde del sistema.
    @ViewBuilder
    func estiloBoton(_ estilo: EstiloBoton) -> some View {
        if estilo == .destructivo {
            buttonStyle(.bordered).foregroundStyle(Paleta.errorTexto)
        } else if #available(macOS 26.0, *), Diseno.vidrioDelSistema {
            switch estilo {
            case .principal: buttonStyle(.glassProminent)
            default: buttonStyle(.glass)
            }
        } else {
            switch estilo {
            case .principal: buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            default: buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }
}

// MARK: - Campos

private struct CampoDestacado: ViewModifier {
    let enfocado: Bool
    let error: Bool

    private var colorBorde: Color {
        if error { return Paleta.error }
        return enfocado ? Paleta.acento : Paleta.bordeFuerte
    }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.vertical, Espacio.m)
            .padding(.horizontal, Espacio.l)
            .background(RoundedRectangle.nuvex(Radio.m).fill(Paleta.campo))
            .overlay {
                RoundedRectangle.nuvex(Radio.m)
                    .strokeBorder(colorBorde, lineWidth: enfocado || error ? Borde.regular : Borde.fino)
            }
            .background {
                // Halo de foco por fuera del borde, como el anillo del sistema.
                RoundedRectangle.nuvex(Radio.m + Borde.foco)
                    .stroke(colorBorde.opacity(0.28), lineWidth: Borde.foco)
                    .padding(-Borde.foco / 2)
                    .opacity(enfocado || error ? 1 : 0)
            }
            .animation(Movimiento.rapida, value: enfocado)
    }
}

extension View {
    /// Campo de texto protagonista (por ejemplo, el código de verificación).
    /// Los campos de formularios usan el estilo del sistema.
    func campoDestacado(enfocado: Bool, error: Bool = false) -> some View {
        modifier(CampoDestacado(enfocado: enfocado, error: error))
    }
}

// MARK: - Movimiento

/// Curvas y duraciones. Las animaciones acompañan un cambio de estado; nunca
/// lo retrasan ni se repiten sin motivo.
enum Movimiento {
    /// Puntero encima, pulsación, foco.
    static let rapida = Animation.snappy(duration: 0.18)
    /// Mostrar u ocultar detalles, cambios de estado.
    static let estandar = Animation.snappy(duration: 0.25)
    /// Cambios de pantalla dentro de una ventana.
    static let suave = Animation.smooth(duration: 0.35)
    /// Con «Reducir movimiento»: un fundido breve en lugar de desplazamientos.
    static let reducida = Animation.easeInOut(duration: 0.15)

    /// Aparición de un bloque bajo su origen (detalles, avisos): fundido con
    /// un leve desplazamiento; solo fundido con «Reducir movimiento».
    static func aparicion(reducir: Bool) -> AnyTransition {
        reducir ? .opacity : .opacity.combined(with: .offset(y: -Espacio.xs))
    }
}

private struct AnimacionAccesible<Valor: Equatable>: ViewModifier {
    let animacion: Animation
    let valor: Valor
    @Environment(\.accessibilityReduceMotion) private var reducir
    func body(content: Content) -> some View {
        content.animation(reducir ? Movimiento.reducida : animacion, value: valor)
    }
}

extension View {
    /// `animation(_:value:)` que respeta «Reducir movimiento».
    func animacion<Valor: Equatable>(_ animacion: Animation, value: Valor) -> some View {
        modifier(AnimacionAccesible(animacion: animacion, valor: value))
    }
}

// MARK: - Componentes

/// Icono de Ajustes: un símbolo blanco sobre un cuadrado redondeado de color,
/// con el reflejo superior de los iconos de macOS.
struct IconoCuadrado: View {
    let simbolo: String
    let color: Color
    var lado: CGFloat = Tamano.iconoLista

    var body: some View {
        let forma = RoundedRectangle.nuvex(Radio.icono(lado))
        forma
            .fill(color.gradient)
            .overlay {
                forma.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.0)],
                                                  startPoint: .top, endPoint: .center),
                                   lineWidth: Borde.fino)
            }
            .overlay { forma.strokeBorder(.black.opacity(0.10), lineWidth: Borde.fino) }
            .frame(width: lado, height: lado)
            .overlay {
                Image(systemName: simbolo)
                    .font(.system(size: lado * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .accessibilityHidden(true)
    }
}

enum ColorConexion {
    static func para(_ id: String) -> Color {
        Paleta.conexiones[id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Paleta.conexiones.count]
    }
}

/// Punto de estado (conectada, atención, error).
struct Indicador: View {
    let color: Color
    var lado: CGFloat = Tamano.indicador

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: Borde.fino))
            .frame(width: lado, height: lado)
            .animacion(Movimiento.estandar, value: color)
    }
}

/// Etiqueta en cápsula: «Beta», «Conectada», «Sin guardar».
struct Pastilla: View {
    let texto: String
    var color: Color = Paleta.neutro
    var conIndicador = false

    var body: some View {
        HStack(spacing: Espacio.xs) {
            if conIndicador {
                Circle().fill(color).frame(width: Tamano.puntoPastilla, height: Tamano.puntoPastilla)
            }
            Text(texto)
                .lineLimit(1)
        }
        .font(Tipo.etiqueta)
        .foregroundStyle(Paleta.texto(color))
        // Con punto, el lado izquierdo es curvo y visualmente más ligero: se
        // compensa con el mismo margen que el hueco entre punto y texto.
        .padding(.leading, conIndicador ? Espacio.s : Espacio.m)
        .padding(.trailing, Espacio.m)
        .frame(minHeight: Tamano.pastilla)
        .background(Capsule().fill(color.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Filas interactivas

/// Fila pulsable a medida (panel de la barra de menús): resaltado suave al
/// pasar el puntero, más intenso al pulsar y atenuada si está desactivada.
/// El foco de teclado lo dibuja el sistema con «Acceso total con teclado».
struct EstiloFila: ButtonStyle {
    var radio: CGFloat = Radio.m

    func makeBody(configuration: Configuration) -> some View {
        Cuerpo(configuration: configuration, radio: radio)
    }

    private struct Cuerpo: View {
        let configuration: Configuration
        let radio: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var activo

        var body: some View {
            configuration.label
                .background(RoundedRectangle.nuvex(radio).fill(relleno))
                .opacity(activo ? 1 : 0.45)
                .contentShape(RoundedRectangle.nuvex(radio))
                .onHover { hover = $0 }
                .animacion(Movimiento.rapida, value: hover)
                .animacion(Movimiento.rapida, value: configuration.isPressed)
        }

        private var relleno: Color {
            guard activo else { return .clear }
            if configuration.isPressed { return Paleta.rellenoIntenso }
            return hover ? Paleta.relleno : .clear
        }
    }
}

/// Respuesta al pulsar un control compacto sin estilo propio (el círculo de
/// una VPN): se hunde levemente; con «Reducir movimiento», solo se oscurece.
struct EstiloPresion: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Cuerpo(configuration: configuration)
    }

    private struct Cuerpo: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reducir
        @Environment(\.isEnabled) private var activo

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reducir ? 0.92 : 1)
                .brightness(configuration.isPressed ? -0.06 : 0)
                .opacity(activo ? 1 : 0.5)
                .animation(Movimiento.rapida, value: configuration.isPressed)
        }
    }
}

/// Copia un texto y confirma con una marca durante un instante.
struct BotonCopiar: View {
    let texto: String
    var etiqueta = "Copiar"
    @State private var copiado = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(texto, forType: .string)
            copiado = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copiado = false
            }
        } label: {
            Image(systemName: copiado ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copiado ? Paleta.exito : Color.secondary)
                .frame(width: Tamano.botonIcono, height: Tamano.botonIcono)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(copiado ? "Copiado" : etiqueta)
        .accessibilityLabel(copiado ? "Copiado" : etiqueta)
    }
}

/// Estado vacío o de fallo que ocupa el lugar de una lista: un icono, un
/// título, una explicación breve y, como mucho, una acción. Centrado y sin
/// contenedor; el icono es lo único que no usa color de estado.
struct EstadoVacio<Icono: View, Accion: View>: View {
    let titulo: String
    let detalle: String
    let icono: Icono
    let accion: Accion

    init(_ titulo: String, detalle: String, @ViewBuilder icono: () -> Icono,
         @ViewBuilder accion: () -> Accion) {
        self.titulo = titulo
        self.detalle = detalle
        self.icono = icono()
        self.accion = accion()
    }

    var body: some View {
        VStack(spacing: Espacio.s) {
            icono
                .padding(.bottom, Espacio.xxs)
            Text(titulo).font(Tipo.encabezado)
            Text(detalle)
                .font(Tipo.apoyo)
                .foregroundStyle(Paleta.textoSecundario)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            accion
                .controlSize(.small)
                .padding(.top, Espacio.s)
        }
        .frame(maxWidth: .infinity)
    }
}

extension EstadoVacio where Icono == SimboloVacio {
    init(_ titulo: String, detalle: String, simbolo: String, @ViewBuilder accion: () -> Accion) {
        self.init(titulo, detalle: detalle, icono: { SimboloVacio(nombre: simbolo) }, accion: accion)
    }
}

/// Símbolo de un estado vacío: grande, jerárquico y en tono secundario.
struct SimboloVacio: View {
    let nombre: String
    var body: some View {
        Image(systemName: nombre)
            .font(Tipo.simboloVacio)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Paleta.textoSecundario)
            .accessibilityHidden(true)
    }
}
