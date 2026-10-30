# Prepare Disk

App macOS qui prépare les disques externes de maintenance : les 3 derniers macOS bootables, les IPSW iPad et Mac Apple Silicon, et les loops GarageBand.

## Installer

1. Télécharger **[PrepareDisk.zip](https://github.com/BobyCharbon/prepare_disk/releases/latest/download/PrepareDisk.zip)** (toujours la dernière version) et le décompresser.
2. Mettre **Prepare Disk.app** dans `Applications`.
3. Première ouverture : clic droit › **Ouvrir** (l'app n'est pas signée par Apple).
4. Réglages Système › Confidentialité et sécurité › **Accès complet au disque** : ajouter Prepare Disk. À faire une seule fois : l'autorisation reste valable pour toutes les versions suivantes.

L'app se met ensuite à jour toute seule au lancement. Dans Réglages › **Mise à jour** : vérifier et mettre à jour à la demande, ou couper la mise à jour automatique.

## Publier une nouvelle version

1. Dans [CHANGELOG.md](CHANGELOG.md), ajouter en haut `## 1.2.0 — date` et quelques lignes simples sur ce qui change.
2. Lancer :

```bash
./release.sh 1.2.0
```

GitHub compile l'app, la signe avec le certificat de l'app et publie la version « v1.2.0 — date » avec ces lignes et le zip à installer.

Toutes les nouveautés : [CHANGELOG.md](CHANGELOG.md).

## Compiler soi-même

```bash
./build_app.sh
```

Crée `Prepare Disk.app` et sa copie `PrepareDisk.zip`.

Il faut les outils de ligne de commande Xcode (Swift 5.9+). Sans le certificat « Prepare Disk » dans le trousseau, l'app est signée ad hoc et l'Accès complet au disque est à redonner à chaque build.
