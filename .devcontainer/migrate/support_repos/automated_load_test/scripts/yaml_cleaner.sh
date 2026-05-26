FILENAME=services
EXTENSION=yaml


declare -a UNWANTEDLINES=('cloud.google' 'meta.helm' 'helm.sh/chart' 'uid:' 'creationTime' 'generation' 'resourceVersion' 'clusterIP' 'app.kubernetes.io/managed-by: Helm' '10.')

# type: ClusterIP

FILE=$FILENAME.$EXTENSION
FILECLEAN=$FILENAME-clean.$EXTENSION

copyFile(){
    cp $FILE $FILECLEAN
}

cleanFile() {
   ## now loop through the above array
   for LINE in "${UNWANTEDLINES[@]}"; do
      printf "Cleaning file : ${FILETOCLEAN} from ${LINE} \n"
      cat $FILECLEAN | grep -v "${LINE}" > $FILECLEAN.tmp
      # Swap files
      cp -f $FILECLEAN.tmp $FILECLEAN
   done
}

#copyFile
#cleanFile