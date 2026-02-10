= Sicurezza e conformità normativa

== Strategia di protezione dei dati

In questa sezione illustro l'approccio che ho adottato per garantire la sicurezza e la conformità del sistema, aspetti critici quando si trattano dati sanitari sensibili.
La mia strategia non si limita alla protezione perimetrale, ma integra la sicurezza direttamente nel design del modello dati e nelle politiche di accesso.

== Controllo degli accessi (RBAC)

Ho implementato un modello di controllo degli accessi basato sui ruoli (*RBAC - Role Based Access Control*).
Invece di assegnare permessi ai singoli utenti, ho definito dei ruoli funzionali (es. *Data Analyst*, *Data Engineer*, *Compliance Officer*) a cui ho associato specifici set di privilegi. Questo mi permette di gestire in modo scalabile e ordinato chi può leggere o scrivere dati.

== Principio del minimo privilegio

Ho applicato rigorosamente il principio del *Least Privilege*: ogni ruolo dispone solo ed esclusivamente dei permessi necessari per svolgere le proprie mansioni.
Questo riduce drasticamente la superficie di attacco e il rischio di accessi non autorizzati o accidentali a informazioni che non competono a un determinato operatore.

== Conformità GDPR

Ho prestato particolare attenzione ai requisiti del GDPR.
A livello concettuale, ho predisposto il sistema per supportare funzionalità come il *Data Masking* (per oscurare dati sensibili a utenti non autorizzati) e il tracciamento degli accessi (Auditing), garantendo che il trattamento dei dati dei pazienti avvenga nel pieno rispetto della normativa vigente.
