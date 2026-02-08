// Helper per formattazione e placeholder
#let screenshot(path, what, where, reason) = {
  figure(
    // In produzione: scommentare image e commentare il blocco rect
    // image("../assets/" + path, width: 90%),
    rect(width: 100%, inset: 12pt, fill: luma(240), stroke: 1pt + rgb("#0078D4"))[
      #align(left)[
        #text(weight: "bold", size: 10pt, fill: rgb("#0078D4"))[SCREENSHOT RICHIESTO: #path] \
        \
        *Cosa mostra:* #what \
        *Dove:* #where \
        *Motivo:* #reason
      ]
    ],
    caption: what,
  )
}

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