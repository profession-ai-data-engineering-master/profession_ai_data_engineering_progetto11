= Generazione e preparazione dei dati sintetici

== Inquadramento della fase

Ho considerato la fase di generazione dei dati sintetici un passaggio strutturale del progetto, finalizzato a produrre dataset realistici e utilizzabili per l'intera pipeline di ingestione e analisi. In questo contesto, non ho trattato la generazione come un mero esercizio di popolamento, ma come un processo controllato volto a riprodurre la complessita' informativa tipica dei sistemi informativi sanitari.

== Obiettivi della generazione

- Ho abilitato test end-to-end della pipeline senza esporre dati reali.
- Ho simulato volumi, distribuzioni e relazioni coerenti tra entita' cliniche e amministrative.
- Ho reso possibile la validazione delle regole di qualita' e dei controlli di conformita'.
- Ho preparato dataset compatibili con l'ingestione in Snowflake e con la successiva modellazione analitica.

== Motivazioni architetturali

Ho scelto di utilizzare dati sintetici per preservare riservatezza e conformita' normativa, mantenendo al contempo un elevato livello di fedelta' rispetto ai processi operativi. In particolare, ho adottato un approccio relazionale per evitare la frammentazione tipica dei dataset scollegati e garantire la coerenza dei flussi di integrazione tra sorgenti eterogenee.

== Collegamento con l'ingestione in Snowflake

Ho progettato la generazione per produrre file di output coerenti con i requisiti di caricamento in Snowflake: schemi stabili, chiavi definite e relazioni esplicite. Con questa impostazione ho ridotto le operazioni di data cleansing in fase di ingestione e posso costruire modelli dimensionali e di data vault senza perdita di integrita' referenziale.

== Coerenza relazionale come requisito primario

Ho considerato la coerenza relazionale una condizione necessaria per riprodurre scenari realistici di un ecosistema sanitario. Ho vincolato pazienti, ricoveri, diagnosi e misurazioni IoT a identificativi consistenti, con cardinalita' e dipendenze gestite in modo esplicito. Ho usato questo requisito per guidare la definizione degli schemi e la selezione degli strumenti di generazione che ho adottato.
