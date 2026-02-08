= Storage su Amazon S3

== Strategia di storage

Ho utilizzato Amazon S3 come storage intermedio privato per i file sintetici destinati a Snowflake. I bucket non sono pubblici, non usano ACL aperte e non espongono credenziali statiche. Ho organizzato i dati per ambiente e sorgente per garantire isolamento, controllo degli accessi e tracciabilita' delle dipendenze. Questa strategia abilita l'accesso sicuro da parte di Snowflake tramite ruolo IAM dedicato e assunzione controllata del ruolo, mantenendo i bucket completamente privati.

== Creazione dei bucket S3

Ho acceduto alla AWS Management Console e ho aperto il servizio S3. Ho selezionato Create bucket, ho impostato il nome del bucket come healthdata-synthetic e ho scelto la regione in linea con i requisiti di residenza dei dati. Ho attivato tutte le opzioni di Block all public access e ho confermato che non fosse presente alcuna policy di accesso pubblico. Ho completato la creazione del bucket con queste impostazioni di sicurezza.

Ho creato i path logici per ambiente e sorgente all'interno del bucket, per esempio:
- dev/ehr/
- dev/erp/
- dev/iot/

Ho verificato nel pannello Permissions che il bucket risultasse non pubblico e che Block all public access fosse attivo su tutte le opzioni.

== Gestione dei ruoli IAM e sicurezza

Ho aperto Services, poi IAM, quindi Roles e Create role. Ho selezionato come trusted entity un servizio esterno configurato per l'assunzione del ruolo da parte di Snowflake. Ho assegnato al ruolo il nome SnowflakeS3AccessRole.

Ho creato una policy IAM dedicata seguendo il principio del *least privilege*. La policy consente solo:
- s3:ListBucket sul bucket healthdata-synthetic
- s3:GetObject sui path necessari per ambiente e sorgente

Ho escluso qualsiasi permesso di scrittura o accesso a percorsi non necessari. Ho associato la policy al ruolo per garantire un accesso centralizzato, tracciabile e revocabile.

== Accesso sicuro ai bucket da Snowflake

Ho configurato il ruolo SnowflakeS3AccessRole per l'assunzione controllata da parte di Snowflake e ho verificato che l'accesso avvenga tramite credenziali temporanee. Questo evita l'uso di chiavi statiche e riduce il rischio di esposizione delle credenziali. La scelta supporta compliance e auditabilita' perche' l'accesso e' tracciato e limitato nel tempo.

Sul lato Snowflake ho creato una STORAGE INTEGRATION dedicata (con `STORAGE_PROVIDER = S3` e `STORAGE_AWS_ROLE_ARN` puntato a SnowflakeS3AccessRole). Ho recuperato i valori `STORAGE_AWS_IAM_USER_ARN` e `STORAGE_AWS_EXTERNAL_ID` con `DESC INTEGRATION` e li ho usati nella trust policy del ruolo IAM. Ho quindi creato lo STAGE esterno con `URL = 's3://healthdata-synthetic/dev/'` e `STORAGE_INTEGRATION = <nome_integrazione>`, e ho validato l'accesso con un `LIST @stage`.

== Configurazione della trust relationship

Ho aperto il ruolo SnowflakeS3AccessRole e sono entrato nella sezione Trust relationships. Ho impostato la relazione di trust per consentire a Snowflake di assumere il ruolo, usando come principal AWS il valore fornito da Snowflake (`STORAGE_AWS_IAM_USER_ARN`) e vincolando l'assunzione con `ExternalId` (`STORAGE_AWS_EXTERNAL_ID`). Ho verificato che non fossero presenti utenti o servizi non autorizzati e ho motivato questa scelta per eliminare la condivisione di chiavi statiche e migliorare la sicurezza dell'accesso.

Esempio di trust policy applicata al ruolo:

```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Principal": {
				"AWS": "<STORAGE_AWS_IAM_USER_ARN>"
			},
			"Action": "sts:AssumeRole",
			"Condition": {
				"StringEquals": {
					"sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID>"
				}
			}
		}
	]
}
```

== Restrizione dell'accesso tramite bucket policy

Ho aperto il bucket S3, sono entrato in Permissions e quindi in Bucket policy. Ho inserito una policy che consente l'accesso solo al ruolo SnowflakeS3AccessRole e che nega qualsiasi altro accesso non autorizzato. Ho salvato la policy e ho ricontrollato che il bucket risultasse non pubblico con Block all public access attivo.

Esempio di bucket policy in sola lettura con path limitati:

```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowSnowflakeList",
			"Effect": "Allow",
			"Principal": {
				"AWS": "arn:aws:iam::ACCOUNT_ID:role/SnowflakeS3AccessRole"
			},
			"Action": "s3:ListBucket",
			"Resource": "arn:aws:s3:::healthdata-synthetic",
			"Condition": {
				"StringLike": {
					"s3:prefix": [
						"dev/ehr/*",
						"dev/erp/*",
						"dev/iot/*"
					]
				}
			}
		},
		{
			"Sid": "AllowSnowflakeRead",
			"Effect": "Allow",
			"Principal": {
				"AWS": "arn:aws:iam::ACCOUNT_ID:role/SnowflakeS3AccessRole"
			},
			"Action": "s3:GetObject",
			"Resource": [
				"arn:aws:s3:::healthdata-synthetic/dev/ehr/*",
				"arn:aws:s3:::healthdata-synthetic/dev/erp/*",
				"arn:aws:s3:::healthdata-synthetic/dev/iot/*"
			]
		}
	]
}
```

== Upload dei dati tramite AWS Management Console

Ho navigato nei path corretti del bucket per ciascuna sorgente e ho utilizzato il pulsante Upload. Ho selezionato i file locali, ho avviato l'upload e ho verificato visivamente la presenza dei file caricati. Ho controllato che i file fossero nel path corretto e che il naming fosse coerente con le tabelle previste.

== Preservazione della coerenza e preparazione all'ingestione

Ho caricato prima le entita' master e poi le tabelle di dettaglio per mantenere la coerenza referenziale. Ho verificato manualmente i file caricati e ho mantenuto naming coerente con il modello dati. La configurazione IAM consente a Snowflake di accedere ai dati con permessi minimi necessari senza rendere i bucket pubblici, proteggendo i dati sanitari e riducendo la superficie di esposizione.
