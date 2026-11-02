# Nouveautés de Prepare Disk

Chaque version commence par `## numéro — date`, suivi de quelques lignes simples.
C'est ce texte qui s'affiche sur GitHub et dans l'app (Réglages › Mise à jour).

## 1.5.4 — 2 novembre 2026

- Mise à jour possible sans mot de passe administrateur : la nouvelle version s'installe alors dans le dossier Applications de l'utilisateur.
- Plus de copies de l'app qui s'empilent après une mise à jour ratée, et une seule fenêtre Prepare Disk à la fois.
- Accès complet au disque : un bouton « Relancer », car macOS ne l'applique qu'au lancement suivant.
- Sur un compte standard, la configuration unique demande le nom et le mot de passe d'un administrateur.

## 1.5.3 — 2 novembre 2026

- Correction de l'affichage sur un Mac neuf : la fenêtre n'est plus coupée en haut et les onglets de gauche s'affichent de nouveau.

## 1.5.2 — 30 octobre 2026

- Icône de la barre des menus plus lisible : un grand ✓ quand tout est à jour, une flèche pendant un téléchargement, un « ! » s'il manque quelque chose.
- Les loops GarageBand ne sont plus dans Versions validées : elles se choisissent dans Préparer un disque.

## 1.5.1 — 30 octobre 2026

- Corrigé : un installateur ou un IPSW vérifié pendant qu'on le copiait restait marqué « abîmé ». Il est maintenant revérifié dès qu'il change, et rien n'est vérifié tant qu'une copie est en cours.
- L'icône de la barre des menus et l'app partagent leurs vérifications.

## 1.5.0 — 30 octobre 2026

- L'app s'ouvre sur Versions validées ; tout réglage manquant (accès complet au disque, configuration unique, arrière-plan, notifications) s'affiche en rouge tout en haut, avec un bouton qui y mène, et disparaît une fois réglé.
- L'icône de la barre des menus s'installe d'office avec l'app.
- Téléchargements : reprise là où ils en étaient après une coupure (Wi-Fi, app quittée, redémarrage), attente du retour du réseau au lieu d'échouer, temps restant plus juste et total en haut de la page.
- Chaque fichier est certifié intact avant d'être marqué « Sur ce Mac » (empreinte SHA-1 des IPSW, signature Apple et version des macOS) ; un fichier abîmé est retéléchargé.
- Les téléchargements de l'icône sont visibles et annulables dans l'app, et l'icône montre ceux de l'app.
- Les anciennes versions sont supprimées définitivement, seulement une fois leur remplaçante certifiée.
- Espace disque libre et nécessaire affiché dans Versions validées et dans l'icône.
- Mise à jour obligatoire : installée seule, même sans droits administrateur ; l'app est bloquée tant qu'elle n'est pas faite.
- La configuration unique ne sera plus jamais à refaire : l'assistant se met à jour tout seul (dernière fois pour cette version).

## 1.4.0 — 30 octobre 2026

- App signée par un développeur Apple et notarisée : elle s'ouvre directement, sans avertissement ni passage par les Réglages.
- Icône dans la barre des menus : elle montre si toutes les versions validées sont sur le Mac, même quand l'app est fermée.
- Téléchargement automatique (interrupteur dans Versions validées) : télécharge seul les versions validées, garde le Mac éveillé, recommence en cas d'échec sans inonder le réseau.
- Les macOS sont téléchargés depuis le paquet officiel d'Apple : plus rapide, plus de blocage sur les anciennes versions, ni passage par Applications.
- Configuration unique : le mot de passe administrateur n'est demandé qu'une seule fois.
- Plus de demande du trousseau au démarrage ni en changeant de version.
- Dernières versions d'Apple en rose, versions validées aux couleurs de l'entreprise ; menu réorganisé.

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
