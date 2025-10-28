#!/bin/bash

set -u
#####################################################
RED="\e[31m"
GREEN="\e[32m"
CYAN="\e[36m"
YELLOW="\e[93m"
BLUE="\e[94m"
ENDCOLOR="\e[0m"

EXTENSIONS="nes,smc,sfc,fig,gb,gbsfc,fig,gb,gbc,gba,bin,md,smd,gen,sms,gg,n64,z64,v64,s64,iso,cso,cue,pbp,PBP,gdi,chd,zip,7z"



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

get_files() {
 # Coleta todos os arquivos de jogos com as extensões especificadas
    shopt -s globstar nullglob
    local -n found=$1 

    IFS=',' read -ra EXTS <<< "$EXTENSIONS"

    for ext in "${EXTS[@]}"; do
    found+=( **/*."$ext" )
    done

}

    declare -A NAME_MAP
find_only_in_xml() {
    # Compara os arquivos encontrados com os do gamelist.xml
    local -n files=$1
    local -n in_xml=$2
    local game=""
    
    for game in "${files[@]}"; do
        NAME_MAP["$game"]=1
        
    done

    # Verificar cada jogo do XML
    local path=""
    local name=""
    while IFS='|' read -r path name; do
        path="${path#./}"  # Remove o prefixo ./

        # Se NÃO está no hash, adiciona
        if [ -z "${NAME_MAP[$path]:-}" ]; then
            in_xml+=("$name")
        
        else #  Atualiza o nome no hash para referência futura
            NAME_MAP["$path"]="$name"   
        fi
    done < <(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "name" -n ./gamelist.xml)

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
    # Converte "nes,chd,zip" em "-name '*.nes' -o -name '*.chd' -o -name '*.zip'" p/ ser usado no find
    local ext_find=$(echo "$EXTENSIONS" | awk -F, '{for(i=1;i<=NF;i++) printf "-name *.%s%s",$i,(i==NF?"":" -o ")}')

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

GAME_FILES=()
ONLY_IN_XML=()
find_games () {
    get_files GAME_FILES
    find_only_in_xml GAME_FILES ONLY_IN_XML

    printf "${GREEN}%s Jogos Encontrados${ENDCOLOR}\n" "${#GAME_FILES[@]}"
    printf "${YELLOW}%s Jogos estão apenas no gamelist.xml${ENDCOLOR}\n" "${#ONLY_IN_XML[@]}"
        
}

SELECTED_GAME=""
select_game () {
    local opt=""

    local game=""
    local game_names=()
    for game in "$@"; do
        game_names+=("${NAME_MAP[$game]}")
    done

    printf "${BLUE}Selecione um jogo:${ENDCOLOR}\n"
    select opt in "${game_names[@]}" "Sair"; do
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

                printf "Jogo selecionado: ${CYAN}%s${ENDCOLOR}\n" "$opt"
                SELECTED_GAME="$opt"
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
        find_games


       ask_user "Ver jogos" "Editar gamelist.xml"

   #else VOLTAR DEPOIS E TERMINAR ESSE CAMINHO
   #    select_dir "${NO_GAMES_DIRS[@]}"
   fi

   if [[ "$USER_ANSWER" -eq 1 ]]; then
       select_game "${GAME_FILES[@]}" 

       while true; do
       ask_user "Mover jogo" "Copiar jogo" "Deletar jogo"
       case "$USER_ANSWER" in
               1)
                   read -p "Digite o caminho de destino: " dest_path
                   printf "MOvendo ${CYAN}%s${ENDCOLOR} para ${CYAN}%s${ENDCOLOR}\n" "$SELECTED_GAME" "$dest_path"
                   #mv "$SELECTED_GAME" "$dest_path"
                   break
                   ;;
               2)
                  echo "Copiar jogo selecionado"
                   break
                   ;;
               3)
                   echo "Deletar jogo selecionado"
                   break
                   ;;
               *)
                   echo "Escolha uma ação válida."
                   continue
                   ;;
           esac
       done 
    fi

}
main "$@"
