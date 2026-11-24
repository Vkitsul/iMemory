# iMemory: documento di progetto

App nativa per macOS che mostra dove finisce lo spazio su disco e aiuta a liberarlo senza rischi.

Stato al 5 novembre 2026: M0 completata. Tutte le tappe, da M1 a M5, sono scritte e verificate con test e con un giro automatico: mancano la prova con mouse e tastiera reali e la prima pulizia sui dati veri, che spetta all'utente.

Destinazione: solo uso personale, su questo Mac con macOS 27. Non è prevista la pubblicazione.

## 1. Cosa dicono i numeri di questo Mac

Misure di sola lettura del 5 novembre 2026, in GB decimali come nel Finder. Sul disco da 245,1 GB sono occupati 192,5 GB, così divisi:

| Volume APFS | Spazio | Nota |
|---|---:|---|
| Dati | 143,5 | vedi sotto |
| Preboot | 20,6 | di sistema, non si tocca |
| Sistema | 18,4 | sigillato, non si tocca |
| VM | 5,4 | memoria virtuale, la gestisce macOS |
| Recovery | 3,1 | di sistema, non si tocca |
| Update | 1,3 | di sistema, non si tocca |

Dentro il volume Dati, con Accesso completo al disco:

| Cartella | Spazio | Nota |
|---|---:|---|
| `/Users` | 74,7 | di cui `~/Library` 58,4 |
| `~/Library/Application Support` | 39,5 | compreso in `/Users`; Claude 11,6, backup di iPhone 7,2, Steam 3,8 |
| `~/Pictures` | 10,5 | compreso in `/Users`; quasi tutto libreria Foto |
| `~/Library/Developer` | 7,5 | compreso in `/Users`; quasi tutto simulatori (7,4) |
| `~/Library/Caches` | 3,4 | compreso in `/Users`; Brave 2,0, Homebrew 0,5 (misurato senza Accesso completo al disco) |
| `/Applications` | 25,8 | |
| `/System/Library/AssetsV2` | 16,3 | di cui runtime del simulatore iOS 8,1 |
| `/private` | 10,3 | |
| `/Library` | 6,6 | |
| **Non attribuito** | **fra 8,5 e 22** | i 143,7 del volume meno i 135,2 allocati o i 121,8 privati |

Dando l'Accesso completo al disco, lo spazio misurato sale da 105,8 a 135,2 GB e le cartelle illeggibili scendono da 898 a 239. Quelle rimaste sono soprattutto di sistema (per esempio in `/private/var`) e richiedono root. Lo spazio non attribuito è un intervallo perché i cloni APFS contano più volte nel totale allocato: lo spazio fisico delle cartelle misurate sta fra 121,8 e 135,2 GB. Può trovarsi nelle cartelle che richiedono root o nei metadati di APFS, ma non è verificato. L'app mostra il valore minimo e lo dichiara come tale.

Tre conseguenze guidano il progetto:

1. **Svuotare le cache rende poco.** Sono 3,4 GB su 192,5, e in gran parte si ricreano. Un'app che fa solo pulizia cache non risolverebbe il problema.
2. **Il valore sta nel capire.** Lo spazio sta soprattutto nei dati delle app, in Foto e nei backup, non nei documenti: fuori da `~/Library` la cartella utente occupa 15,4 GB, di cui 10,5 sono immagini. Per questo la funzione principale è l'esplorazione, con la pulizia subito accanto.
3. **Una stessa cartella ha più dimensioni.** `/Applications` vale 32,3 GB logici, 25,8 allocati e 21,3 privati. Mostrare il numero sbagliato significa promettere spazio che non si libera.

## 2. Principi

1. **Nessuna cancellazione senza anteprima.** Si vede sempre l'elenco esatto prima di agire.
2. **Numeri onesti.** Lo spazio liberato è misurato sul volume dopo l'operazione, non stimato. Spostare nel Cestino non conta come liberato.
3. **Ogni voce spiega se stessa.** Cos'è, chi la crea, cosa succede se la elimini, se si ricrea.
4. **Niente allarmismi.** Nessun punteggio di salute, nessun "pericolo" inventato, nessuna pulizia della RAM.
5. **Funziona senza rete.** Nessun dato sui file lascia il Mac.

### Fuori ambito, di proposito

- **Pulizia della RAM.** macOS gestisce già la memoria, e svuotarla a forza rallenta il sistema perché deve ricaricare ciò che aveva in cache.
- **Cancellazione di file protetti da SIP** e modifiche a `/System`.
- **Snapshot di sistema.** Su questo Mac ci sono solo snapshot `com.apple.os.update`, di proprietà degli aggiornamenti: si mostrano e non si toccano.

## 3. Funzioni

| Sezione | Cosa fa | Versione |
|---|---|---|
| Panoramica | Spazio per categoria, cartelle più grandi, cosa è cresciuto dall'ultima scansione, azioni consigliate | 1.0 |
| Esplora | Treemap ed elenco navigabili, con filtri per tipo, età e dimensione | 1.0 |
| Pulizia | Cache e log vecchi, guidati da regole e raggruppati per livello di rischio. I residui delle app arrivano con la sezione App | 1.0 |
| Sviluppatore | Simulatori, DerivedData, supporto dispositivi, Homebrew, pip, npm. `node_modules` e Docker non sono inclusi: su questo Mac non ci sono, quindi non si potrebbero provare | 1.0 |
| App | Dimensione, spazio che torna davvero, ultimo utilizzo se noto, disinstallazione con residui | 1.1 |
| File grandi e vecchi | File oltre 100 MB fuori da Libreria, cartelle nascoste e pacchetti, filtrabili per tipo ed età | 1.1 |
| Duplicati | Copie vere, escludendo i cloni APFS che non occupano spazio doppio. Almeno una copia resta sempre | 1.2 |
| Automazione | Icona nella barra dei menu, avviso di spazio basso, pulizie programmate delle sole voci sicure, disattivate di partenza | 1.3 |
| Cronologia | Ogni operazione con file, spazio misurato ed esito | 1.0 |

La funzione che distingue di più l'app è **"cosa è cresciuto"**: confrontando le scansioni salvate si vede subito che una cartella ha preso 12 GB questa settimana.

## 4. Sicurezza della pulizia

Ogni voce appartiene a uno di quattro livelli.

| Livello | Esempi | Selezione predefinita | Come si elimina |
|---|---|---|---|
| Sicuro | Cache di Homebrew, pip e npm, log non modificati da 30 giorni | Sì | Eliminazione diretta |
| Da valutare | Cache del browser e di Steam, DerivedData, dati dei simulatori | No | Eliminazione diretta, oppure comando dello strumento |
| Personale | App, residui, file grandi, duplicati | No, mai: li sceglie l'utente | Cestino |
| Protetto | Portachiavi, `Application Support` senza regola, dati di sistema | Non selezionabile | Mai |

Nelle cache il Cestino non servirebbe: lo spazio resterebbe occupato finché non viene svuotato.

`Application Support` è protetto per impostazione predefinita, anche se pesa molto, perché contiene dati veri mescolati alle cache. Si interviene solo su sottocartelle coperte da una regola esplicita.

### Percorso di ogni eliminazione

Il codice è in `Sources/CleanKit`, l'unico modulo che può modificare il disco.

1. **Piano.** Elenco immutabile di voci con regola, identificativo del file e dimensione attesa, mostrato prima di agire.
2. **Controlli subito prima di agire:**
   - la regola è ancora valida e le radici del piano sono quelle che nomina
   - le app proprietarie non sono aperte (controllo ripetuto per ogni regola)
   - la radice si apre un componente alla volta, senza seguire link, e ha lo stesso identificativo della scansione
   - ogni voce ha lo stesso identificativo della scansione, altrimenti si salta
3. **Esecuzione.** Ogni passaggio apre un solo componente relativo a una cartella già aperta e rifiuta i link. Un link messo ovunque, anche durante l'eliminazione, non può portarla fuori dalla sua cartella. Non attraversa altri volumi e non scarica file dal cloud. Le voci comparse dopo la scansione restano.
4. **Verifica.** Si legge lo spazio del volume subito prima e subito dopo, senza attese, e il risultato va in Cronologia. APFS libera lo spazio all'istante, mentre aspettare lascia entrare nella misura ciò che scrivono le altre app: in una prova, 12 MB al secondo di scritture altrui hanno ridotto 400 MB a 143 in 20 secondi. Se il dato misurato e i byte dei file eliminati divergono, il report li mostra entrambi.

### Spostamento nel Cestino

App, residui e file personali vanno sempre nel Cestino, da cui si recuperano. Il report lo dichiara: lo spazio si libera solo svuotandolo, e l'app non lo svuota. `TrashPolicy` ammette solo:

- **app:** un bundle `.app` nelle cartelle delle app, al massimo una sottocartella più in basso
- **residui:** figli diretti di cartelle note di `~/Library`, mai la cartella stessa, e mai ad esempio `Keychains` o `Mail`
- **file:** file normali nella Home, fuori da `~/Library`, da cartelle nascoste come `.git` e dall'interno dei pacchetti come la libreria Foto

Prima di spostare ogni voce si riapre il percorso senza seguire link e si confronta l'identificativo con la scansione. Se l'app è aperta non si sposta nulla. Se il sistema rifiuta, ad esempio per un'app di proprietà di root come Xcode, l'errore finisce nel report senza chiedere privilegi: si sposta dal Finder.

**Residui.** Quanto è trovato per identificativo esatto e non è dati dell'app parte selezionato. I dati dell'app, che possono contenere lavoro dell'utente, e quanto è trovato solo per nome partono sempre non selezionati.

**Ultimo utilizzo.** Viene da Spotlight, che lo conosce per 11 app su 53 su questo Mac. Quando manca l'app scrive "non noto", mai "mai usata".

### Duplicati

`DuplicateKit` confronta i file oltre 1 MB nella Home, con le stesse esclusioni dei file grandi, a costo crescente: stessa dimensione, stesso inizio e fine, poi SHA-256 dell'intero contenuto. Non scarica file dal cloud. La ricerca parte solo su richiesta, perché legge i file.

- **Cloni:** file che condividono lo stesso clone contano come una sola copia. Un gruppo fatto solo di cloni non compare.
- **Selezione:** nessun file parte selezionato, e `DuplicateSelection` rifiuta di togliere tutte le copie di un gruppo.
- **Copia da tenere:** al momento di spostare si verifica che esista ancora e sia la stessa della scansione, altrimenti non si sposta nulla.

### Pulizie programmate

Sono l'unica eccezione al principio «nessuna cancellazione senza anteprima», quindi hanno limiti stretti:

- sono **disattivate di partenza**, e un file di impostazioni assente o danneggiato le lascia spente
- riguardano solo voci «Sicuro» che eliminano file: mai comandi, app, file personali o voci da valutare
- la prima avviene dopo un intero intervallo dall'attivazione, e la schermata elenca cosa eliminerebbe adesso
- ogni esecuzione finisce in Cronologia, segnata come programmata
- girano solo mentre l'app è aperta: l'avvio al login non c'è, e servirebbe prima un certificato stabile

### Regole come dati

Le regole stanno in `Sources/RulesKit/catalog.json`, compilato nell'app, così si possono rivedere senza toccare il motore:

```json
{
  "id": "homebrew.cache",
  "title": "Cache di Homebrew",
  "explanation": "Pacchetti già scaricati. Homebrew li riscarica se servono.",
  "level": "safe",
  "roots": ["~/Library/Caches/Homebrew"],
  "ownerProcesses": []
}
```

Una regola può nominare solo cartelle ammesse da una lista scritta nel codice (`RootPolicy`): sottocartelle di `~/Library/Caches` e `~/.npm`, più `~/Library/Logs`. Un errore nel catalogo può quindi puntare al massimo a un'altra cache, mai a documenti o a `Application Support`, e un catalogo con una regola non valida viene rifiutato per intero. Le prossime tappe allargheranno questa lista solo dove serve.

Anche i comandi degli strumenti stanno in una lista chiusa nel codice (`CommandPolicy`), scritti per intero con percorso assoluto: `xcrun simctl delete unavailable`, `xcrun simctl erase all`, `brew cleanup --prune=all`. Partono senza shell, quindi nulla negli argomenti può essere interpretato, e con un limite di tempo. La cartella dei simulatori è ammessa solo per un comando, mai per l'eliminazione diretta.

Un comando compare solo se ha qualcosa da fare: lo si chiede allo strumento in sola lettura (`simctl list`, `brew cleanup --dry-run`). Per un comando la stima è un massimo, «fino a», perché ciò che libera davvero lo decide lo strumento. La cache di Homebrew resta una regola a sé, così si vede il dettaglio delle voci; il comando compare solo se c'è altro oltre la cache.

## 5. Architettura

**Stack:** Swift 6 e SwiftUI, AppKit dove serve, moduli SwiftPM e nessuna dipendenza esterna per il motore. Sul Mac ci sono già Xcode 27.2 e Swift 6.4.

```
iMemoryApp (SwiftUI)
   ├── ScanKit       scansione, albero in memoria, scansioni salvate
   ├── RulesKit      catalogo regole e classificazione
   ├── CleanKit      piano, controlli, esecuzione, cronologia
   ├── DuplicateKit  dimensione → hash parziale → hash completo
   └── AppsKit       app installate, residui, ultimo utilizzo
```

Solo `CleanKit` può modificare il disco. Gli altri moduli sono di sola lettura, e questo confine rende la parte rischiosa piccola e testabile.

### Scansione

Il motore è in `Sources/ScanKit`, la CLI è `imemory-scan`, il confronto con `du` è `Scripts/compare-du.sh`. La prova iniziale resta in `Spikes/ScanSpike`.

**Scelta: `getattrlistbulk`**, per precisione:

- riconosce gli hard link tramite l'identificativo del file, mentre `FileManager` li conta più volte (44 MiB di troppo nelle cache)
- legge `ATTR_CMNEXT_PRIVATESIZE`, necessario per stimare lo spazio davvero recuperabile

**Risultati sul volume Dati**, con 1,03 milioni di voci e senza Accesso completo al disco:

| Thread | Tempo | Tempo di sistema | Picco di memoria |
|---:|---:|---:|---:|
| 1 | 37,6 s | 11,6 s | 220 MB |
| 2 | 21,8 s | 13,2 s | 216 MB |
| **4 (predefinito)** | **13,4 s** | **14,9 s** | **195 MB** |
| 8 | 11,9 s | 22,7 s | 202 MB |

Sono tempi a cache calda. Con 8 thread si guadagna l'11% di tempo ma costa il 52% in più di CPU di sistema, quindi il predefinito è 4.

**Con Accesso completo al disco**, 1,25 milioni di voci e 4 thread:

| Misura | Tempo | Picco di memoria |
|---|---:|---:|
| Dopo `sudo purge` | 14,9 s | 252 MB |
| A caldo | 14,7 s | 251 MB |

I due tempi sono quasi uguali, quindi `purge` potrebbe non svuotare i metadati del file system. Il vero caso a freddo, subito dopo il riavvio, non è stato misurato.

**Confronto con `du`:** eseguendo scansione, `du` e di nuovo scansione, il totale di `du` cade fra le due scansioni in tutte e tre le prove, compresa quella con Accesso completo al disco. Le due scansioni differiscono di 1-2 MiB su 126 GiB perché il disco è in uso, soprattutto in `/private/var`, quindi la verifica non può essere più precisa di così.

**Differenze note rispetto a `du`:**

- oltre `PATH_MAX` `du` si ferma con un errore e riporta 0, mentre il motore legge il file
- il punto di montaggio `/home` pesa 1 KiB per `du` e 0 per il motore
- un hard link può finire in una cartella diversa, con lo stesso totale: `du` lo attribuisce al primo percorso incontrato, il motore sempre al percorso minore (esempio: 72 KiB del binario di Brave, con un secondo link in `/private/var/folders`)
- `du` può far scaricare le cartelle cloud per elencarle, quindi lo script le esclude da entrambe le misure

Altri punti del motore:

- **Tre dimensioni per ogni nodo:** logica, allocata, privata. La UI mostra quella allocata; le stime di recupero usano la privata.
- **Stima di recupero.** La somma dei privati è un minimo: due cloni nella stessa cartella risultano entrambi "condivisi", ma eliminandoli insieme si libera il loro spazio. Per le app `RecoveryEstimator` legge `ATTR_CMNEXT_CLONEID` e `ATTR_CMNEXT_CLONE_REFCNT`, e conta lo spazio condiviso solo se tutti i file che lo condividono sono nell'insieme. Coincide con lo spazio davvero liberato entro 10 MB nei test su 150 MB. Su questo Mac Xcode occupa 4,24 GB, ma disinstallandola ne tornano 1,26.
- **Hard link deterministici:** il proprietario è il percorso minore, così due scansioni non mostrano crescite inesistenti.
- **File solo nel cloud:** non vengono mai scaricati. Verificato su Google Drive, OneDrive e iCloud: 396 file e 12 cartelle riconosciuti, spazio identico prima e dopo la scansione.
- **Altri volumi:** la radice è `/System/Volumes/Data` e la scansione non attraversa altri dispositivi, per non contare due volte i firmlink.
- **Memoria:** l'albero occupa 106 MB per 1,25 milioni di voci, entro l'obiettivo di 150 MB. Il picco temporaneo durante la scansione è di 252 MB per circa 15 secondi, accettabile su questo Mac con 8 GB; si può ridurre se in M1 diventasse un problema.

Da fare nelle tappe successive: aggiornamenti incrementali con FSEvents e scansioni salvate per il confronto nel tempo.

### Scansioni bloccate

Mentre macOS aspetta la risposta a una richiesta di permesso, `open()` resta fermo. Dopo 8 secondi senza nuove voci l'app lo segnala, e "Annulla" funziona comunque: l'attesa finisce subito e il thread fermo termina da solo quando il sistema lo rilascia. Con la firma ad hoc ogni compilazione conta come un'app nuova e queste richieste possono ripresentarsi, un motivo in più per il certificato stabile.

### Interfaccia e reattività

L'app è in `Sources/iMemoryApp`, in SwiftUI. Si compila con `Scripts/build-app.sh`, che crea `build/iMemory.app`. `Scripts/check-app.sh` le fa percorrere un giro fisso e registra il blocco massimo del thread principale.

**Elenco in `NSTableView`, non in `Table` di SwiftUI.** Con 42 680 righe, riordinare in `Table` bloccava l'app fino a 12,5 secondi, perché confronta ogni riga. `NSTableView` ricarica solo le righe visibili.

**Filtri e ordinamenti in background** sopra le 5000 righe, così il thread principale resta libero.

**Risultati** con 1,04 milioni di voci, senza Accesso completo al disco, su questo Mac:

| Operazione | Blocco massimo |
|---|---:|
| Entrare in una cartella | 35-110 ms |
| Ordinare, cercare e filtrare con 42 680 righe | 40-90 ms |
| Selezionare una riga | 10-20 ms |
| Ridimensionare la finestra | 25-100 ms |
| Tornare a Panoramica | 150 ms |
| Riaprire Esplora | 250 ms |
| Prima apertura di Esplora | 350-520 ms |

Il costo di queste operazioni dipende dal contenuto della cartella aperta e non dalle voci totali, ma con 1,25 milioni di voci non è stato misurato. Cambiare sezione è la parte più lenta: si può ridurre tenendo Esplora in memoria, se nell'uso reale dà fastidio.

### Permessi e distribuzione

- **Accesso completo al disco:** necessario per una scansione completa. L'app funziona anche senza, segnalando chiaramente cosa non ha potuto leggere.
- **Niente sandbox, quindi niente Mac App Store.** La sandbox impedirebbe di leggere e pulire le cartelle delle altre app.
- **Distribuzione:** nessuna. L'app si compila e si esegue su questo Mac, quindi non servono notarizzazione, aggiornamenti automatici né traduzioni: l'interfaccia è solo in italiano.
- **Versione minima:** macOS 27, senza codice di compatibilità per versioni precedenti.
- **Firma:** sul Mac non c'è ancora nessun certificato. Con la firma ad hoc macOS collega l'Accesso completo al disco alla singola build, quindi il permesso andrebbe ridato dopo ogni compilazione. Dalla tappa M1 serve un certificato stabile: quello gratuito "Apple Development", che si ottiene aggiungendo il proprio Apple ID in Xcode. La CLI di M0 non ne ha bisogno, perché usa i permessi del terminale da cui parte.
- **Niente helper privilegiato nella 1.0.** Tutto ciò che è nella cartella utente non richiede privilegi di amministratore, e un helper aggiunge una superficie d'attacco. Si valuta con `SMAppService` solo se servirà per `/Library/Caches`.

## 6. Interfaccia

Finestra unica con barra laterale: Panoramica, Esplora, Pulizia, Sviluppatore, Cronologia.

- **Panoramica:** barra dello spazio, cosa è cresciuto, azioni consigliate con lo spazio recuperabile.
- **Esplora:** treemap a sinistra, elenco a destra, percorso in alto. Selezionare in uno aggiorna l'altro.
- **Pannello dettagli:** tre dimensioni, ultima modifica, app proprietaria, spiegazione della regola.
- **Conferma:** riepilogo con numero di voci, spazio stimato come intervallo, e cosa succede dopo.

Durante la scansione si vedono voci trovate e spazio misurato, e si può annullare. I risultati si possono navigare solo alla fine: con circa 15 secondi di scansione non vale ancora la complessità di un albero parziale.

## 7. Test

- **Motore:** confronto automatico con `du` su alberi con hard link, cloni, link simbolici, file sparsi e file iCloud non scaricati.
- **Misure sul disco:** i test che confrontano lo spazio del volume stanno in un'unica suite in serie, perché affiancati si falsano a vicenda.
- **Sicurezza:** `CleanKit` lavora solo su una Home finta in una cartella temporanea, con casi avversi: link simbolici nella radice, nel percorso e dentro le cartelle, percorsi con `..`, file e cartelle sostituiti dopo la scansione, app proprietaria aperta, hard link, file protetti, cartelle illeggibili, volume montato dentro la cartella, percorsi oltre `PATH_MAX`.
- **Giro automatico:** `Scripts/check-app.sh` percorre anche una pulizia completa dalle schermate, su una Home finta. Non chiama mai la pulizia sui dati reali.
- **Regole:** validazione del catalogo. Nessuna regola può puntare a radici vietate come `~`, `~/Documents`, `~/Library/Application Support` o `/`.
- **Non coperto da test automatici:** file solo nel cloud dentro una cartella da pulire. Il comportamento è impostato (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`), ma non è possibile creare questi file in una prova.

## 8. Tappe

| Tappa | Contenuto | Criterio di completamento |
|---|---|---|
| M0 (fatta) | `ScanKit` e CLI | Totali uguali a `du` su tutto il disco, tempi e memoria misurati dopo `sudo purge`; manca solo la misura dopo un riavvio |
| M1 (da provare a mano) | App in sola lettura: Panoramica, Esplora | Blocchi sotto i 110 ms navigando con 1,04 milioni di voci; mancano la prova con mouse e tastiera e la misura con Accesso completo al disco |
| M2 (da provare sui dati veri) | `RulesKit`, `CleanKit`, Pulizia, Cronologia | Test avversi superati; su Home finta spazio misurato entro il 5% dell'atteso (60,4 MB su 60 MB nell'app); manca la prima pulizia reale, che spetta all'utente |
| M3 (da provare sui dati veri) | Sezione Sviluppatore | Comandi in lista chiusa e provati con esecuzioni simulate; `simctl erase all` e `brew cleanup` non sono mai stati eseguiti davvero: la prima volta spetta all'utente |
| M4 (da provare sui dati veri) | App e file grandi | Stima del recupero verificata con eliminazioni reali su file di prova; disinstallazione provata su un'app finta con un Cestino finto; lo spostamento di un'app vera nel Cestino vero non è mai stato eseguito |
| M5 (da provare sui dati veri) | Duplicati e automazione | Nessun clone APFS segnalato come duplicato, verificato con cloni veri; ricerca reale su questo Mac in sola lettura; notifiche, menu della barra e pulizia programmata reale mai eseguiti |

Nelle prime due tappe l'app non può cancellare nulla: la parte rischiosa arriva quando le misure sono già verificate.

## 9. Punti aperti

- **Volumi esterni:** esclusi dalla 1.0, salvo necessità.
