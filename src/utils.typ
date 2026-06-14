// Helper per formattazione
#let note_box(content) = {
  block(
    fill: luma(250),
    stroke: (left: 3pt + rgb("#0078D4")), // Azure Blue
    inset: 12pt,
    width: 100%,
    radius: 4pt,
    content
  )
}

#let project_title = "Gestione dei Dati dei Pazienti con Snowflake"
#let author_name = "Federico Vita"