# Nouveautés de Prepare Disk

Chaque version commence par `## numéro — date`, suivi de quelques lignes simples.
C'est ce texte qui s'affiche sur GitHub et dans l'app (Réglages › Mise à jour).

## 1.1.0 — 30 octobre 2026

- Chaque IPSW est reconnu par son contenu (modèles d'iPad et numéro de build), plus seulement par son nom : un fichier renommé ou posé dans le mauvais dossier est repéré et proposé au rangement.
- « Tout ranger » ne demande le mot de passe qu'une seule fois.
- L'app se met à jour toute seule : elle relit les fichiers en continu et vérifie les versions d'Apple régulièrement, plus besoin du bouton Actualiser.

## 1.0.0 — 30 octobre 2026

- Première version de l'app, qui remplace le script prepare_disk.
- Télécharge les 3 macOS validés et crée le disque bootable (une partition par macOS + DataExternalDrive).
- Ajoute les IPSW iPad et Mac (seulement des versions encore signées par Apple) et, si on veut, les loops GarageBand.
- Onglet « Versions validées » : toutes les versions au même endroit, « sur ce Mac » et « dernière version Apple » visibles d'un coup d'œil, bouton « Tout télécharger ».
- Range tout dans ~/prepare_disk, renomme les IPSW « Modèle - Version », retrouve les fichiers ailleurs sur le Mac et les range en un clic (un seul mot de passe).
- Un téléchargement raté recommence tout seul ; les anciennes versions vont à la corbeille une fois les nouvelles téléchargées.
- Compare un disque déjà préparé avec les versions validées et les dernières d'Apple.
- Se met à jour toute seule depuis GitHub.
