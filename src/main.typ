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
#include "sections/02_piano_azione.typ"
#include "sections/03_dati_sintetici.typ"
#include "sections/04_analisi_requisiti.typ"
#include "sections/05_architettura_snowflake.typ"
#include "sections/06_modello_dati.typ"
#include "sections/07_sicurezza_conformita.typ"
#include "sections/08_conclusioni.typ"
