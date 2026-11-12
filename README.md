# GTA MOD : The PNJ Lab

Laboratoire d'expérimentation sur les PNJ (comportements, animations, interactions).

## Fonctionnalités

Commande `gather` :

- `gather` : téléporte les PNJ sur le joueur
- `gather walk` : les fait marcher jusqu'au joueur
- `gather tp waypoint` : les téléporte sur le repère posé sur la carte
- `gather walk waypoint` : les fait marcher jusqu'au repère posé sur la carte
- `gather walk 215 -810 30` : les fait marcher jusqu'à des coordonnées précises (x y z)
- `gather follow` : active/désactive le suivi continu du joueur (tant que c'est activé, les PNJ suivent le joueur où qu'il aille) ; donner un ordre de destination explicite désactive automatiquement le suivi

Si la ressource `foule_throttle` est démarrée et qu'une foule a été générée, ces ordres s'appliquent à la foule entière, quel que soit son effectif (10, 300, 1000...). Sinon, ils s'appliquent aux PNJ ambiants chargés autour du joueur (hors joueurs, PNJ en véhicule, animaux et PNJ morts).

Un nouvel ordre remplace toujours proprement le précédent, même s'il est encore en train de s'appliquer (changement de direction en cours de route, ordres donnés à la suite sans bug).

## Prérequis

- Serveur FiveM à jour
- (Optionnel) Le mod `foule_throttle` démarré avant, pour cibler sa foule à la place des PNJ ambiants

## Installation

1. Télécharge ce dépôt et renomme le dossier `gtamod-pnj-lab` en `pnj_lab`
2. Copie le dossier `pnj_lab` dans `resources/`
3. Ajoute `ensure pnj_lab` dans ton `server.cfg` (après `ensure foule_throttle` si tu l'utilises)
4. Redémarre le serveur

## Utilisation

Tape les commandes dans le chat (touche T, avec un `/` devant : `/gather walk`) ou dans la console F8. Les retours s'affichent en notification au-dessus de la minimap.

## Structure du dossier

```
pnj_lab/
├─ client.lua           -- script principal (commande /gather)
├─ fxmanifest.lua
└─ README.md
```

## Crédits

Tuto et mod réalisés par :
Alice MASSART, PAD EMD 2026.
