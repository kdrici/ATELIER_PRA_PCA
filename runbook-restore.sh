
#!/bin/bash

set -e
 
NAMESPACE="pra"

JOB_FILE="pra/50-job-restore-pitr.yaml"
 
echo ""

echo "-------------------------------------------------------------"

echo "              RUNBOOK DE RESTAURATION PRA                    "

echo "-------------------------------------------------------------"

echo ""
 
# 1 — Suspension

echo "[ ÉTAPE 1 ] Suspension de l'application et du CronJob..."

kubectl -n $NAMESPACE scale deployment flask --replicas=0

kubectl -n $NAMESPACE patch cronjob sqlite-backup -p '{"spec":{"suspend":true}}'

kubectl -n $NAMESPACE delete job --all --ignore-not-found=true 2>/dev/null

echo "  ✔ Application arrêtée, CronJob suspendu."

echo ""
 
# 2 — Liste des backups via un pod dédié

echo " Backups disponibles :"

echo ""
 
# Création d'un pod temporaire monté sur pra-backup

kubectl -n $NAMESPACE apply -f - <<PODEOF

apiVersion: v1

kind: Pod

metadata:

  name: list-backups

  namespace: $NAMESPACE

spec:

  restartPolicy: Never

  volumes:

    - name: backup

      persistentVolumeClaim:

        claimName: pra-backup

  containers:

    - name: list

      image: alpine

      command: ["sh", "-c", "ls -1t /backup/app-*.db 2>/dev/null | xargs -I{} basename {} || echo VIDE"]

      volumeMounts:

        - name: backup

          mountPath: /backup

PODEOF
 
# Attendre que le pod finisse

kubectl -n $NAMESPACE wait --for=condition=ready pod/list-backups --timeout=30s 2>/dev/null || true

sleep 3
 
BACKUP_LIST=$(kubectl -n $NAMESPACE logs list-backups 2>/dev/null)

kubectl -n $NAMESPACE delete pod list-backups --ignore-not-found=true 2>/dev/null
 
if [ -z "$BACKUP_LIST" ] || [ "$BACKUP_LIST" = "VIDE" ]; then

  echo "  ✘ Aucun backup trouvé. Abandon."

  kubectl -n $NAMESPACE scale deployment flask --replicas=1

  kubectl -n $NAMESPACE patch cronjob sqlite-backup -p '{"spec":{"suspend":false}}'

  exit 1

fi
 
echo "$BACKUP_LIST" | nl -ba -nrz -w3

echo ""
 
# 3 — Choix du point de restauration

echo "[ ÉTAPE 3 ] Entrez le nom du fichier à restaurer (ENTRÉE = le plus récent) :"

read -rp "  > " RESTORE_FILE

echo ""
 
if [ -z "$RESTORE_FILE" ]; then

  RESTORE_FILE=$(echo "$BACKUP_LIST" | head -1 | tr -d '[:space:]')

  echo "  → Backup sélectionné automatiquement : $RESTORE_FILE"

else

  echo "  → Backup sélectionné : $RESTORE_FILE"

fi

echo ""
 
# 4 — Lancement du job

echo "[ ÉTAPE 4 ] Lancement du job de restauration..."

kubectl -n $NAMESPACE delete job sqlite-restore-pitr --ignore-not-found=true 2>/dev/null

sleep 2
 
sed "s/value: \"\"/value: \"$RESTORE_FILE\"/" $JOB_FILE | kubectl apply -f -

kubectl -n $NAMESPACE wait --for=condition=complete job/sqlite-restore-pitr --timeout=90s
 
echo ""

kubectl -n $NAMESPACE logs job/sqlite-restore-pitr

echo "  ✔ Restauration OK"

echo ""
 
# 5 — Redémarrage

echo "[ ÉTAPE 5 ] Redémarrage de l'application..."

kubectl -n $NAMESPACE scale deployment flask --replicas=1

kubectl -n $NAMESPACE patch cronjob sqlite-backup -p '{"spec":{"suspend":false}}'

echo "  ✔ Application et CronJob relancés."

echo ""
 
# 6 — Vérification

echo "[ ÉTAPE 6 ] Vérification..."

sleep 4

kubectl -n $NAMESPACE get pods

echo ""

echo "  → kubectl -n pra port-forward svc/flask 8080:80 &"

echo "  → curl http://localhost:8080/count"

echo "  → curl http://localhost:8080/status"

echo ""

echo "------------------------------------------------------------- "

echo "                    RESTAURATION COMPLÈTE                     "

echo "------------------------------------------------------------- "

