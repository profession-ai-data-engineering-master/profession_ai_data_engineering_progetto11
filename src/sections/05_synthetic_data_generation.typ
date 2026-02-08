= Generazione dei dati sintetici con SDV

== Inquadramento tecnico

Ho realizzato la generazione dei dati sintetici in Python tramite la libreria *SDV (Synthetic Data Vault)*, che ho scelto per la sua capacita' di modellare relazioni tra tabelle e produrre dataset multipli coerenti. L'approccio che ho adottato utilizza metadata relazionali condivisi e un singolo processo di sintesi, in modo da preservare le dipendenze tra entita' cliniche, amministrative e IoT.

== Impostazione delle metadata relazionali

Ho definito le metadata come elemento centrale per garantire l'integrita' referenziale. Ho dichiarato esplicitamente chiavi primarie e chiavi esterne, consentendo a SDV di generare dataset relazionalmente consistenti.

```py
from sdv.metadata import MultiTableMetadata
from sdv.multi_table import HMASynthesizer
import pandas as pd

metadata = MultiTableMetadata()

metadata.add_table(name="patients", primary_key="patient_id")
metadata.add_table(name="admissions", primary_key="admission_id")
metadata.add_table(name="diagnoses", primary_key="diagnosis_id")
metadata.add_table(name="wards", primary_key="ward_id")
metadata.add_table(name="staff", primary_key="staff_id")
metadata.add_table(name="staff_assignments", primary_key="assignment_id")
metadata.add_table(name="devices", primary_key="device_id")
metadata.add_table(name="vital_signs", primary_key="measurement_id")

metadata.add_relationship(parent_table_name="patients", parent_primary_key="patient_id",
                          child_table_name="admissions", child_foreign_key="patient_id")
metadata.add_relationship(parent_table_name="wards", parent_primary_key="ward_id",
                          child_table_name="admissions", child_foreign_key="ward_id")
metadata.add_relationship(parent_table_name="admissions", parent_primary_key="admission_id",
                          child_table_name="diagnoses", child_foreign_key="admission_id")
metadata.add_relationship(parent_table_name="staff", parent_primary_key="staff_id",
                          child_table_name="staff_assignments", child_foreign_key="staff_id")
metadata.add_relationship(parent_table_name="wards", parent_primary_key="ward_id",
                          child_table_name="staff_assignments", child_foreign_key="ward_id")
metadata.add_relationship(parent_table_name="wards", parent_primary_key="ward_id",
                          child_table_name="devices", child_foreign_key="ward_id")
metadata.add_relationship(parent_table_name="patients", parent_primary_key="patient_id",
                          child_table_name="vital_signs", child_foreign_key="patient_id")
metadata.add_relationship(parent_table_name="devices", parent_primary_key="device_id",
                          child_table_name="vital_signs", child_foreign_key="device_id")
```

== Sorgente EHR

Ho generato la sorgente EHR insieme alle altre tabelle per evitare disallineamenti di chiavi. Ho sintetizzato le tabelle cliniche mantenendo riferimenti validi ai pazienti e ai reparti.

```py
# Dati seed provenienti da template o mock controllati
real_tables = {
    "patients": patients_df,
    "admissions": admissions_df,
    "diagnoses": diagnoses_df,
    "wards": wards_df,
    "staff": staff_df,
    "staff_assignments": staff_assignments_df,
    "devices": devices_df,
    "vital_signs": vital_signs_df,
}

synthesizer = HMASynthesizer(metadata)
synthesizer.fit(real_tables)

synthetic_tables = synthesizer.sample(scale=2.0)

synthetic_tables["patients"].to_csv("out/ehr/patients.csv", index=False)
synthetic_tables["admissions"].to_csv("out/ehr/admissions.csv", index=False)
synthetic_tables["diagnoses"].to_csv("out/ehr/diagnoses.csv", index=False)
```

== Sorgente ERP

Per la componente ERP ho garantito la coerenza tramite la stessa istanza di sintesi. Ho vincolato la tabella delle assegnazioni operative a reparti e personale realmente presenti.

```py
synthetic_tables["wards"].to_csv("out/erp/wards.csv", index=False)
synthetic_tables["staff"].to_csv("out/erp/staff.csv", index=False)
synthetic_tables["staff_assignments"].to_csv("out/erp/staff_assignments.csv", index=False)
```

== Sorgente IoT

Ho prodotto le misurazioni IoT con collegamenti espliciti a pazienti e dispositivi, assicurando che ogni parametro vitale faccia riferimento a entita' esistenti.

```py
synthetic_tables["devices"].to_csv("out/iot/devices.csv", index=False)
synthetic_tables["vital_signs"].to_csv("out/iot/vital_signs.csv", index=False)
```

== Preservazione delle relazioni tra entita'

Ho utilizzato SDV per generare dataset multipli in modo coordinato, evitando ID non presenti nelle tabelle master. L'approccio con metadata condivise e campionamento congiunto mi garantisce che ricoveri, diagnosi e misurazioni IoT risultino sempre collegati a pazienti reali e a reparti e dispositivi coerenti.
