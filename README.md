# Idle Crystal Corp

Le projet Godot original et les intégrations Apple sont conservés sans modification sous [ios/README.md](ios/README.md). Ouvrir `ios/project.godot` avec Godot 4.7. Les chemins internes et les scripts iOS restent relatifs au même dossier qu'avant le déplacement.

[android/README.md](android/README.md) contient l'export Android. Il réutilise exactement les mêmes scènes, moteur et données de `ios/`, dans une copie de travail générée hors du dépôt. Le nom `ios/` conserve l'organisation demandée ; le GDScript qu'il contient est commun aux deux plateformes et n'est pas dupliqué dans une deuxième source.

La première version Android est une version de test : partie locale, boutique/publicités simulées sans paiement réel. Les plug-ins Apple ne sont pas portés vers Google Play, AdMob Android ou les notifications Android. Aucun commit ni publication automatique n'est déclenché par les scripts.