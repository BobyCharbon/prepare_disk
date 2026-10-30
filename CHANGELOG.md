# Nouveautés de Prepare Disk

Chaque version commence par `## numéro — date`, suivi de quelques lignes simples.
C'est ce texte qui s'affiche sur GitHub et dans l'app (Réglages › Mise à jour).

## 1.3.0 — 30 octobre 2026

- Mode administrateur activable d'un clic, en haut de Versions validées : on peut changer et télécharger d'autres versions sans rien publier, et publier seulement si on le veut.
- En coupant le mode administrateur, le Mac revient à la liste publiée.
- « Versions validées » est maintenant tout en haut du menu, et « Préparer un disque » a sa propre section.

## 1.2.0 — 30 octobre 2026

- Versions validées centralisées : l'administrateur choisit les versions et les publie, tous les Mac les reçoivent automatiquement (au démarrage et toutes les 30 minutes).
- Sur les Mac des utilisateurs, ces versions sont verrouillées ; une notification invite à télécharger les nouvelles.
- Nouvel onglet Réglages › Administration pour activer le mode administrateur.
- L'app se met à jour toute seule, sans réglage : au démarrage, puis toutes les heures dès que rien n'est en cours.

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
