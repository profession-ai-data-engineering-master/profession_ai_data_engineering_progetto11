#import "utils.typ": *

#set page(
  paper: "a4",
  margin: (x: 2cm, y: 2cm),
  numbering: "1",
)
#set text(
  font: "New Computer Modern",
  size: 11pt,
  lang: "it",
)
#set heading(numbering: "1.1")

// Frontespizio
#align(center + horizon)[
  #text(size: 24pt, weight: "bold", fill: rgb("#0078D4"))[
    #project_title
  ]
  \ \ \
  #text(size: 14pt)[Progetto di Data Engineering con Snowflake]
  \ \ \
  #line(length: 50%, stroke: 1pt)
  \ \ \
  #text(size: 12pt)[
    *Autore:* #author_name \
    *Data:* #datetime.today().display("[day]/[month]/[year]")
  ]
]
#pagebreak()

// Indice
#outline(
  title: "Indice dei Contenuti",
  indent: auto,
)
#pagebreak()

// Sezioni
#include "sections/01_contesto_e_obiettivo.typ"
