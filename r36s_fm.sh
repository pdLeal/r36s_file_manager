#!/bin/bash

#####################################################
dirs=(*/)
check_dir () {
    local total_dirs=$(printf '%s\n' "${dirs[@]}" | wc -l)
    printf '\e[32m%s Subpastas Encontradas\e[0m\n' "$total_dirs"

}

games_dirs=()
no_games_dirs=()
look4_roms () {
    local extensions="nes,smc,sfc,fig,gb,gbc,gba,bin,md,smd,gen,sms,gg,n64,z64,v64,s64,iso,cso,cue,pbp,gdi,chd,zip,7z"
    
    # Converte "nes,chd,zip" em "-name '*.nes' -o -name '*.chd' -o -name '*.zip'"
    local ext_find=$(echo "$extensions" | awk -F, '{for(i=1;i<=NF;i++) printf "-name *.%s%s",$i,(i==NF?"":" -o ")}')

    for dir in "${dirs[@]}"; do
    # Itera sobre cada diretório e checa se a saída de FIND ñ é uma string vazia -n
     if [ -n "$(find "$dir" -type f -name "gamelist.xml" -printf '%h\n')" ]; then
    
        if find "$dir" -maxdepth 1 -type f \( $ext_find \) -print -quit| grep -q .; then
        # Procura por pelo menos 1 arquivo com as extensões especificadas
            games_dirs+=("$dir")

        else
            no_games_dirs+=("$dir")
        fi

    else
        continue
    fi
done


}

main () {
    echo "Avaliando Diretório"
    check_dir

    echo "Procurando por subpastas contendo ROMs..."
    look4_roms
    printf '\e[32m%s Subpastas contendo ROMs\e[0m\n' "${#games_dirs[@]}" 
    printf '\e[91m%s Subpastas possuem apenas "gamelist.xml"\e[0m\n' "${#no_games_dirs[@]}" 

}
main "$@"




#printf "O que deseja fazer?\n1) Ver ROMs\n2) Ver Outros\n"
#read -p "Escolha: " user_option
#
#case "$user_option" in
#    1)
#        echo "Subpastas com ROMs"
#        ;;
#    2)
#        echo "Subpastas sem ROMs"
#        ;;
#    *)
#        echo "Opção inválida. Saindo..."
#        exit 1
#        ;;
#esac



#PS3="Escolha um num: "
#select dir in "${gamelist_dirs[@]}" "Sair"; do
#   case "$dir" in
#       "Sair")
#           echo "Saindo..."
#           exit 0
#           ;;
#       *)
#           if [[ ! $REPLY =~ ^[0-9]+$ ]] || [ "$REPLY" -lt 1 ] || [ "$REPLY" -gt "${#gamelist_dirs[@]}" ]; then
#           # Verifica se a entrada é um número, se ñ é < 1 ou > q o número de opções
#               echo "Opção inválida. Tente novamente."
#               continue
#           fi
#           printf 'Entrando na subpasta: \e[36m%s\e[0m\n' "$dir"
#           cd "$(pwd)/$dir"
#           break
#           ;;
#   esac
#done
#
## Coleta todos os arquivos de jogos com as extensões especificadas
#shopt -s globstar nullglob
#game_files=( **/*.{nes,smc,sfc,fig,gb,gbc,gba,bin,md,smd,gen,sms,gg,n64,z64,v64,s64,iso,cso,cue,pbp,gdi,chd,zip,7z} )
#
#printf '\e[93m%s Jogos Encontrados\e[0m\n' "${#game_files[@]}"
#for game in "${game_files[@]}"; do
#    echo "$game"
#done

# Extrai caminhos e nomes dos jogos do gamelist.xml
#mapfile -t paths < <(awk -F'[<>]' '/<path>/{print $3}' gamelist.xml)
#mapfile -t names < <(awk -F'[<>]' '/<name>/{print $3}' gamelist.xml)


#echo "${#names[@]} jogos encontrados: ${#paths[@]} caminhos correspondentes."


#select name in "${names[@]}" "Sair"; do
#    case "$name" in
#        "Sair")
#            echo "Saindo..."
#            exit 0
#            ;;
#        *)
#            if [[ ! $REPLY =~ ^[0-9]+$ ]] || [ "$REPLY" -lt 1 ] || [ "$REPLY" -gt "${#names[@]}" ]; then
#                echo "Opção inválida. Tente novamente."
#                continue
#            fi
#            selected_name="$name"
#            break
#            ;;
#    esac
#done
#
#printf 'Você selecionou: \e[36m%s\e[0m\n' "$selected_name"  
#
#while true; do
#read -p "O que deseja fazer com este jogo? Mover-> mv, Copiar-> cp, Deletar-> rm, Sair: " action
#case "$action" in
#        mv)
#            read -p "Digite o caminho de destino para mover o jogo: " dest_path
#            break
#            ;;
#        cp)
#            read -p "Digite o caminho de destino para copiar o jogo: " dest_path
#            break
#            ;;
#        rm)
#            printf 'Deletando o jogo: \e[31m%s\e[0m\n' "$selected_name"
#            break
#            ;;
#        Sair)
#            echo "Saindo..."
#            exit 0
#            ;;
#        *)
#            echo "Escolha uma ação válida."
#            continue
#            ;;
#    esac
#done

#games=()
#for i in "${!paths[@]}"; do
#    games+=("${names[i]}|${paths[i]}")
#done            
#
#for game in "${games[@]}"; do
#    echo "$game"
#done