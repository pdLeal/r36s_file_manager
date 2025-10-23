#!/bin/bash

set -u
#####################################################
RED="\e[31m"
GREEN="\e[32m"
CYAN="\e[36m"
YELLOW="\e[93m"
BLUE="\e[94m"
ENDCOLOR="\e[0m"
# FUNÇÕES AUXILIARES
is_valid_option () {
# Verifica se a entrada é um número, se ñ é < 1 ou > q o número de opções 
    local input="$1"
    local max_option="$2"

    if [[ ! $input =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt "$max_option" ]; then
        return 1  # Inválido
    else
        return 0  # Válido
    fi
}

#####################################################
DIRS=(*/)
check_dir () {
    local total_dirs=$(printf '%s\n' "${DIRS[@]}" | wc -l)
    printf "${GREEN}%s Subpastas Encontradas${ENDCOLOR}\n" "$total_dirs"

}

GAMES_DIRS=()
NO_GAMES_DIRS=()
look4_roms () {
    local extensions="nes,smc,sfc,fig,gb,gbc,gba,bin,md,smd,gen,sms,gg,n64,z64,v64,s64,iso,cso,cue,pbp,gdi,chd,zip,7z"
    
    # Converte "nes,chd,zip" em "-name '*.nes' -o -name '*.chd' -o -name '*.zip'" p/ ser usado no find
    local ext_find=$(echo "$extensions" | awk -F, '{for(i=1;i<=NF;i++) printf "-name *.%s%s",$i,(i==NF?"":" -o ")}')

    for dir in "${DIRS[@]}"; do
    # Itera sobre cada diretório e checa se a saída de FIND ñ é uma string vazia -n
     if [ -n "$(find "$dir" -type f -name "gamelist.xml" -printf '%h\n')" ]; then
    
        if find "$dir" -maxdepth 1 -type f \( $ext_find \) -print -quit| grep -q .; then
        # Procura por pelo menos 1 arquivo com as extensões especificadas
            GAMES_DIRS+=("$dir")

        else
            NO_GAMES_DIRS+=("$dir")
        fi
    fi
done


}

ask_user () {
    local opt=""
    printf "${BLUE}O que deseja fazer?${ENDCOLOR}\n"
    select opt in "$@" "Sair"; do
        case "$opt" in
            "Sair")
                echo "Saindo..."
                exit 0
                ;;
            *)
                if ! is_valid_option "$REPLY" "$#"; then
                    printf "${RED}Opção inválida. Tente novamente.${ENDCOLOR}\n"
                    continue
                fi

                USER_ANSWER="$REPLY"
                break
                ;;
        esac
    done

}

select_dir () {
    local opt=""
    printf "${BLUE}Selecione uma subpasta:${ENDCOLOR}\n"
    select opt in "$@" "Sair"; do
        case "$opt" in
            "Sair")
                echo "Saindo..."
                exit 0
                ;;
            *)
                if ! is_valid_option "$REPLY" "$#"; then
                    printf "${RED}Opção inválida. Tente novamente.${ENDCOLOR}\n"
                    continue
                fi

                printf "${CYAN}Entrando na subpasta: %s${ENDCOLOR}\n" "$opt"
                cd "$(pwd)/$opt"
                break
                ;;
        esac
    done

}

main () {

    echo "Avaliando Diretório..."
    check_dir

    echo "Procurando por subpastas contendo ROMs..."
    look4_roms
    printf "${GREEN}%s Subpastas contendo ROMs${ENDCOLOR}\n" "${#GAMES_DIRS[@]}" 
    printf "${YELLOW}%s Subpastas possuem apenas "gamelist.xml"${ENDCOLOR}\n" "${#NO_GAMES_DIRS[@]}" 

    ask_user "Ver subpastas com ROMs" "Ver subpastas sem ROMs"
    if [[ "$USER_ANSWER" -eq 1 ]]; then
        select_dir "${GAMES_DIRS[@]}"
    else
        select_dir "${NO_GAMES_DIRS[@]}"
    fi

    ask_user "Listar jogos" "Copiar jogo" "Mover jogo" "Deletar jogo"
    




}
main "$@"

#
## Coleta todos os arquivos de jogos com as extensões especificadas
#shopt -s globstar nullglob
#game_files=( **/*.{nes,smc,sfc,fig,gb,gbsfc,fig,gb,gbc,gba,bin,md,smd,gen,sms,gg,n64,z64,v64,s64,iso,cso,cue,pbp,gdi,chd,zip,7z} )
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