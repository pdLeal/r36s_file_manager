#!/bin/bash

echo "Avaliando Diretório"

dirs=(*/)
total_dirs=$(printf '%s\n' "${dirs[@]}" | wc -l)
printf '\e[32m%s Subpastas Encontradas\e[0m\n' "$total_dirs"

echo "Procurando por subpastas contendo ROMs..."

gamelist_dirs=()
for dir in "${dirs[@]}"; do  # Itera sobre cada diretório e checa se a saída de FIND ñ é uma string vazia -n
    #if [ -n "$(find "$dir" -mindepth 1 -print -quit)" ]; then

        # printf '\e[36m%s\e[0m não está vazio.\n' "$dir"
     
     if [ -n "$(find "$dir" -type f -name "gamelist.xml" -printf '%h\n')" ]; then
        gamelist_dirs+=("$dir")
    else
        continue
    fi
done
printf '\e[32m%s Subpastas de Jogos Encontradas\e[0m\n' "${#gamelist_dirs[@]}"

PS3="Escolha um num: "
select dir in "${gamelist_dirs[@]}" "Sair"; do
   case "$dir" in
       "Sair")
           echo "Saindo..."
           exit 0
           ;;
       *)
            
           cd "$(pwd)/$dir"
           echo "$dir $REPLY"
           exit 0 
           ;;
   esac
done