from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak, KeepTogether
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase import pdfmetrics
from reportlab.lib.colors import HexColor
from pathlib import Path

out=Path('output/pdf/Mapa-de-menus-La-Reyna-Xpress.pdf')
nav=[
('Panel principal',[('Dashboard','Resumen general del restaurante.')]),
('Administración y dirección',[
('Inteligencia Administrativa','Indicadores ejecutivos, alertas, tendencias y acciones para investigar.'),
('DRE','Estado de resultados, ventas netas por canal y movimientos manuales.'),
('SUP','Maestros y parámetros operativos.'),
('Gerente','Bitácora, mantenimiento, incidentes y registros operativos.'),
('Inversión / Registro Empresarial','Socios, acciones, aportes y movimientos de capital.'),
('Créditos y Préstamos','Obligaciones, saldos, vencimientos y pagos.'),
('Finanzas','Presupuesto, gastos operativos, margen de contribución y punto de equilibrio.')]),
('Recursos humanos',[
('Empleados','Fichas, jornadas clock-in/clock-out, costo estimado por hora, documentos y roles internos.'),
('Dieta y Consumos','Registro de comidas y consumos del personal.')]),
('Catálogos y datos maestros',[
('Productos','Catálogo de productos con costos, unidades y referencias.'),('Ingredientes','Insumos y materias primas.'),('Categorías','Clasificación y unidades.'),('Proveedores','Directorio de proveedores y datos de contacto.'),('Comparación Proveedores','Cotizaciones e historial de precios comparables.')]),
('Compras y abastecimiento',[
('Compras','Compras, recepción, pagos y documentos asociados.'),('Lista de Compras','Necesidades de abastecimiento y seguimiento.')]),
('Inventario',[
('Inventario','Existencias, ubicaciones, lotes y alertas.'),('Movimientos','Entradas, salidas y ajustes.'),('Merma','Pérdidas, rendimientos y registros de merma.')]),
('Producción y cocina',[
('Recetas','Recetas finales, costos, rendimientos y fichas.'),('Pre-elaborados','Preparaciones base y costos.'),('Producción','Lotes, productividad, etiquetas y flujo de nevera.'),('Cocina','Tareas, notas y operación de cocina.'),('Bar','Bebidas, recetas, producción y merma.'),('Food Cost','Costeo y metas de Food Cost.'),('Menu Engineering','Análisis de platos, costos, contribución y decisiones.')]),
('Ventas y POS',[
('POS / Ventas','Ventas por canal, pagos, descuentos y reportes.'),('Rentabilidad','Análisis de margen y rentabilidad.'),('Promociones / Marketing','Promociones y precios promocionales.'),('Eventos & Catering','Cotizaciones, costos y operación de eventos.')]),
('Documentos y cumplimiento',[
('Activos Digitales y Accesos','Cuentas, URLs, credenciales protegidas, permisos y archivos.'),('Documentos','Archivo documental empresarial.'),('Documentos y Permisos','Licencias, responsables y vencimientos con alertas.'),('NAS / Archivo Documental','Archivo documental, tipos y vencimientos.')]),
('Operación',[
('Checklists','Tareas de apertura, cierre y operación.'),('Recursos','Manuales, procedimientos y capacitación.')]),
('Reportes y control',[
('Reportes','Exportaciones e informes.'),('Auditoría y Control','Trazabilidad de acciones y eventos del sistema.')]),
('Herramientas',[
('Calculadora','Cálculos de costos, comisiones, descuentos y márgenes.'),('Convertidor de Medidas','Conversión de unidades personalizadas.'),('Bloc de Notas','Notas operativas.')]),
('Configuración y control',[
('Configuración','Metas, canales, idioma, descarga/restauración de respaldos y recuperación local.')]),
]
styles=getSampleStyleSheet()
styles.add(ParagraphStyle(name='TitleLRX',parent=styles['Title'],fontName='Helvetica-Bold',fontSize=22,leading=27,textColor=HexColor('#163a67'),spaceAfter=8,alignment=TA_LEFT))
styles.add(ParagraphStyle(name='SubLRX',parent=styles['Normal'],fontName='Helvetica',fontSize=9.4,leading=14,textColor=HexColor('#5f6e82'),spaceAfter=10))
styles.add(ParagraphStyle(name='GroupLRX',parent=styles['Heading2'],fontName='Helvetica-Bold',fontSize=13,leading=17,textColor=HexColor('#163a67'),spaceBefore=10,spaceAfter=6,keepWithNext=True))
styles.add(ParagraphStyle(name='ModuleLRX',parent=styles['BodyText'],fontName='Helvetica-Bold',fontSize=9.1,leading=12,textColor=HexColor('#1b2a41')))
styles.add(ParagraphStyle(name='DescLRX',parent=styles['BodyText'],fontName='Helvetica',fontSize=8.4,leading=11,textColor=HexColor('#596579')))
styles.add(ParagraphStyle(name='SmallLRX',parent=styles['BodyText'],fontName='Helvetica',fontSize=8,leading=11,textColor=HexColor('#65758b')))

def footer(canvas,doc):
    canvas.saveState(); w,h=A4
    canvas.setStrokeColor(HexColor('#dbe2eb'));canvas.line(18*mm,15*mm,w-18*mm,15*mm)
    canvas.setFont('Helvetica',8);canvas.setFillColor(HexColor('#708096'))
    canvas.drawString(18*mm,10*mm,'La Reyna Xpress · Mapa de navegación · 9 octubre 2026')
    canvas.drawRightString(w-18*mm,10*mm,f'Página {doc.page}')
    canvas.restoreState()

doc=SimpleDocTemplate(str(out),pagesize=A4,rightMargin=18*mm,leftMargin=18*mm,topMargin=17*mm,bottomMargin=21*mm,title='Mapa de menús - La Reyna Xpress',author='La Reyna Xpress')
story=[Paragraph('Mapa de menús',styles['TitleLRX']),Paragraph('La Reyna Xpress · Estructura de navegación actual observada en el código de la aplicación.',styles['SubLRX']),Paragraph('Esta guía enumera los grupos del menú y los módulos visibles. La descripción resume la función principal de cada módulo; no sustituye la revisión de permisos de cada usuario.',styles['SmallLRX']),Spacer(1,3*mm)]
for group,items in nav:
    story.append(Paragraph(group,styles['GroupLRX']))
    data=[[Paragraph('<b>Módulo</b>',styles['ModuleLRX']),Paragraph('<b>Contenido principal</b>',styles['ModuleLRX'])]]
    for module,desc in items:
        data.append([Paragraph(module,styles['ModuleLRX']),Paragraph(desc,styles['DescLRX'])])
    t=Table(data,colWidths=[56*mm,120*mm],repeatRows=1,hAlign='LEFT')
    t.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(-1,0),HexColor('#eef3fa')),
        ('TEXTCOLOR',(0,0),(-1,0),HexColor('#163a67')),
        ('GRID',(0,0),(-1,-1),.35,HexColor('#dbe2eb')),
        ('VALIGN',(0,0),(-1,-1),'TOP'),
        ('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),
        ('TOPPADDING',(0,0),(-1,-1),5),('BOTTOMPADDING',(0,0),(-1,-1),5),
        ('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,HexColor('#fbfcfe')]),
    ]))
    story.append(t)
    story.append(Spacer(1,2*mm))
story.append(Spacer(1,3*mm));story.append(Paragraph('Nota de alcance: “Agenda de Contactos” y las mejoras de punto de equilibrio, distribución a socios y dieta con catálogo aparecen en los requerimientos de trabajo, pero aún no son módulos independientes en el menú actual.',styles['SmallLRX']))
doc.build(story,onFirstPage=footer,onLaterPages=footer)
print(out.resolve())
