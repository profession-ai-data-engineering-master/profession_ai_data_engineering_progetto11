= Validazione analitica e query dimostrative

== Obiettivo della validazione

In questa fase finale, eseguo una serie di interrogazioni mirate per confermare tre aspetti fondamentali del progetto:
1.  *Completezza*: i dati sono fluiti correttamente dal livello RAW al livello ANALYTICS.
2.  *Qualità*: la logica di quarantena ha intercettato eventuali anomalie referenziali.
3.  *Sicurezza*: le policy di mascheramento dinamico proteggono i dati sensibili in base al ruolo utente.

I test vengono eseguiti impersonando i ruoli definiti nel modello di sicurezza (`ROLE_DATA_ENGINEER`, `ROLE_DATA_ANALYST`, `ROLE_COMPLIANCE_OFFICER`).

== 1. Verifica tecnica del flusso (Data Engineering)

Utilizzando il ruolo tecnico, verifico la cardinalità delle tabelle lungo la pipeline per accertarmi che non ci siano perdite di dati non giustificate (es. record scartati).

*Role: ROLE_DATA_ENGINEER*

#figure(
  ```sql
  USE ROLE ROLE_DATA_ENGINEER;
  USE WAREHOUSE WH_OPERATIONS;

  -- 1. Confronto conteggi tra layer (EHR Pazienti)
  SELECT 'RAW' as LAYER, COUNT(*) as CNT FROM HEALTHCARE_DW.RAW.PAZIENTI
  UNION ALL
  SELECT 'CURATED' as LAYER, COUNT(*) as CNT FROM HEALTHCARE_DW.CURATED.PAZIENTI
  UNION ALL
  SELECT 'ANALYTICS' as LAYER, COUNT(*) as CNT FROM HEALTHCARE_DW.ANALYTICS.DIM_PAZIENTE;
  ```,
  caption: "Query di riconciliazione volumi tra i layer"
)

// Screenshot suggerito: sf_results_layer_count.png
#figure(
  image("../assets/sf_results_layer_count.png", width: 80%),
  caption: "Screenshot: output verifica volumi (nessuna perdita di dati)"
)

== 2. Verifica gestione anomalie (Quarantena)

Controllo se le tabelle di quarantena hanno catturato record che violano l'integrità referenziale (es. misurazioni di un dispositivo sconosciuto). Un risultato vuoto indica che i dati sintetici sono consistenti, ma la presenza delle tabelle garantisce robustezza.

*Role: ROLE_DATA_ENGINEER*

#figure(
  ```sql
  USE ROLE ROLE_DATA_ENGINEER;
  
  -- Verifica contenuti in quarantena
  SELECT 'RICOVERI_BAD' as TIPO, COUNT(*) as RIGHE_SCARTATE 
  FROM HEALTHCARE_DW.CURATED.RICOVERI_QUARANTENA
  UNION ALL
  SELECT 'VITALS_BAD' as TIPO, COUNT(*) as RIGHE_SCARTATE 
  FROM HEALTHCARE_DW.CURATED.PARAMETRI_VITALI_QUARANTENA;
  ```,
  caption: "Monitoraggio della Data Quality (Quarantena)"
)

// Screenshot suggerito: sf_results_quarantine_empty.png
#figure(
  image("../assets/sf_results_quarantine_empty.png", width: 80%),
  caption: "Screenshot: output verifica quarantena (nessuna anomalia non gestita)"
)

== 3. Analisi di Business (Data Analyst)

Simulo l'attività di un analista che interroga il Data Mart per estrarre insight. Questa query coinvolge Fact Table e Dimensioni, validando le Join dello Star Schema.
*Usecase*: Analisi della durata media dei ricoveri (LOS) per reparto.

*Role: ROLE_DATA_ANALYST*

#figure(
  ```sql
  USE ROLE ROLE_DATA_ANALYST;
  USE WAREHOUSE WH_ANALYTICS;

  SELECT 
      d.NOME_REPARTO,
      d.SPECIALITA,
      COUNT(f.ID_RICOVERO) as TOTALE_RICOVERI,
      ROUND(AVG(f.DURATA_DEGENZA_GIORNI), 1) as AVG_DEGENZA_GIORNI
  FROM HEALTHCARE_DW.ANALYTICS.FACT_RICOVERI f
  JOIN HEALTHCARE_DW.ANALYTICS.DIM_REPARTO d 
      ON f.ID_REPARTO = d.ID_REPARTO
  GROUP BY 1, 2
  ORDER BY AVG_DEGENZA_GIORNI DESC;
  ```,
  caption: "Analisi dimensionale: Ricoveri per Reparto"
)

// Screenshot suggerito: sf_results_analytics_query.png
#figure(
  image("../assets/sf_results_analytics_query.png", width: 80%),
  caption: "Screenshot: risultati analisi degenza media per reparto"
)

== 4. Verifica Masking Policy (Security & Compliance)

Infine, dimostro l'efficacia delle Masking Policy sui dati PII (`DIM_PAZIENTE.CITTA` e `DATA_NASCITA`).

*Test 1: Vista Analista (Dati Mascherati)*
L'analista deve vedere `** MASKED **` e la data sentinel `1900-01-01`.

#figure(
  ```sql
  USE ROLE ROLE_DATA_ANALYST;

  SELECT TOP 5
      ID_PAZIENTE,
      CITTA,         -- Atteso: ** MASKED **
      DATA_NASCITA,  -- Atteso: 1900-01-01
      PIANO_ASSICURATIVO
  FROM HEALTHCARE_DW.ANALYTICS.DIM_PAZIENTE;
  ```,
  caption: "Accesso mascherato per Data Analyst"
)

// Screenshot suggerito: sf_results_masked_analyst.png
#figure(
  image("../assets/sf_results_masked_analyst.png", width: 80%),
  caption: "Screenshot: vista mascherata per ruolo Data Analyst"
)

*Test 2: Vista Compliance (Dati in Chiaro)*
Il Compliance Officer, avendo privilegi di audit, vede i dati originali.

#figure(
  ```sql
  USE ROLE ROLE_COMPLIANCE_OFFICER;

  SELECT TOP 5
      ID_PAZIENTE,
      CITTA,         -- Atteso: Valore reale (es. Roma, Milano)
      DATA_NASCITA,  -- Atteso: Valore reale
      PIANO_ASSICURATIVO
  FROM HEALTHCARE_DW.ANALYTICS.DIM_PAZIENTE;
  ```,
  caption: "Accesso unmasked per Compliance Officer"
)

// Screenshot suggerito: sf_results_unmasked_compliance.png
#figure(
  image("../assets/sf_results_unmasked_compliance.png", width: 80%),
  caption: "Screenshot: vista in chiaro per ruolo Compliance Officer"
)
