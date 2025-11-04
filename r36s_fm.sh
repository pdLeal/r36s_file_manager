#!/usr/bin/env bash
# r36s_fm.sh - Gerenciador de arquivos de jogos para R36s
# Autor: pleal
# Data: 18/10/2025

set -u
#####################################################
# VARIÁVEIS GLOBAIS E CONSTANTES
#####################################################

# Cores para saída no terminal
readonly RED="\e[31m"
readonly GREEN="\e[32m"
readonly YELLOW="\e[33m"
readonly BLUE="\e[34m"
readonly CYAN="\e[36m"
readonly ENDCOLOR="\e[0m"

# Extensões de arquivos de jogos suportadas
readonly EXTENSIONS=("nes" "smc" "sfc" "fig" "gb" "gbsfc" "fig" "gb" "gbc" "gba" "bin" "md" "smd" "gen" "sms" "gg" "n64" "z64" "v64" "s64" "iso" "cso" "cue" "pbp" "PBP" "gdi" "chd" "zip" "7z")


#####################################################
# FUNÇÕES
#####################################################

is_valid_option () {
# Verifica se a entrada é um número, se ñ é < 1 ou > q o número de opções/argumentos 
    local input="$1"
    local max_option="$2"
    local msg="${3:-"Opção inválida."}"

    if [[ ! "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 ]] || [[ "$input" -gt "$max_option" ]]; then
        printf "${BLUE}$msg Tente Novamente${ENDCOLOR}\n"
        return 1  # Inválido
    else
        return 0  # Válido
    fi
}

get_files() {
# Coleta todos os arquivos com as extensões especificadas e popula o array fornecido
    shopt -s globstar nullglob
    local -n found="$1"
    local ext=""

    for ext in "${EXTENSIONS[@]}"; do
    found+=( **/*."$ext" )
    done

    shopt -u globstar nullglob
}

find_only_in_xml() {
# Compara os arquivos encontrados com os do gamelist.xml e identifica quais estão apenas no XML.
    # Parâmetros:
    #   $1 - (array, referência) Lista de arquivos encontrados
    #   $2 - (array, referência) Lista de nomes de jogos presentes apenas no gamelist.xml
    #   $3 - (associative array, referência) Mapeamento de arquivos para nomes de jogos
    # Retorno:
    #   Popula $2 com nomes de jogos que estão apenas no gamelist.xml
    #   Atualiza $3 com nomes de jogos encontrados

    local -n files="$1"
    local -n in_xml="$2"
    local -n map="$3"
    local file=""
    
    # Criar um hash dos arquivos encontrados
    for file in "${files[@]}"; do
        map["$file"]="__UNSET__"  # Valor temporário
        
    done

    # Verificar cada jogo do XML
    local path=""
    local name=""
    while IFS='|' read -r path name; do
        path="${path#./}"  # Remove o prefixo ./

        # Se NÃO está no hash, adiciona - Obs:path tem o msm nome do arquivo/jogo
        if [[ -z "${map["$path"]:-}" ]]; then
            in_xml+=("$name")
        
        else #  Atualiza o nome no hash para referência futura
            map["$path"]="$name"   
        fi
    done < <(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "name" -n ./gamelist.xml)

}

cleanup() {
    if [[ -n "${TMP_GAME:-}" ]]; then
    echo "Limpando arquivos temporários..."
    rm -f "$TMP_GAME" "$TMP_OUT" "$TMP_XSL" 
    fi
}
trap cleanup EXIT 

#####################################################

look4_roms () {
# Procura por arquivos de jogos nas pastas fornecidas
    local -n dirs=$1
    local -n w_games=$2
    local -n w_no_games=$3

    local first=1 # flag para a primeira iteração
    local ext=""
    local ext_find=""

    # Converte EXTENSIONS na string "-name '*.nes' -o -name '*.chd' -o -name '*.zip'" p/ ser usado no find
    for ext in "${EXTENSIONS[@]}"; do
        if (( first )); then
          ext_find+=" -name "*.${ext}" "
          first=0
        else
          ext_find+=" -o -name "*.${ext}" "
        fi
    done


    # Checa se existe ao menos um arquivo chamado "gamelist.xml" em $dir.
    # Se existir, find imprime o diretório pai (%h) e a condição [-n ...] será verdadeira.
    for dir in "${dirs[@]}"; do
     if [ -n "$(find "$dir" -type f -name "gamelist.xml" -printf '%h\n')" ]; then
    
        # Procura por pelo menos 1 arquivo com as extensões especificadas e popula os arrays correspondentes
        if find "$dir" -maxdepth 1 -type f \( $ext_find \) -print -quit| grep -q .; then
            w_games+=("$dir")
        else
            w_no_games+=("$dir")
        fi
    fi
done


}

ask_user () {
# Exibe um menu de opções para o usuário e armazena a escolha em user_answer
    local -n answer=$1
    shift
    local opt=""

    printf "${RED}O que deseja fazer?${ENDCOLOR}\n"
    select opt in "$@" "Sair"; do
        case "$opt" in
            "Sair")
                echo "Saindo..."
                exit 0
                ;;
            *)
                ! is_valid_option "$REPLY" "$#" && continue # pula para próxima iteração se a opção fornecida for inválida
                
                answer="$REPLY"
                break
                ;;
        esac
    done

}

select_dir () {
# Exibe um menu de seleção de diretórios para o usuário entra no diretóirio escolhido
    local opt=""
    printf "${RED}Selecione uma pasta:${ENDCOLOR}\n"
    select opt in "$@" "Sair"; do
        case "$opt" in
            "Sair")
                echo "Saindo..."
                exit 0
                ;;
            *)
                ! is_valid_option "$REPLY" "$#" && continue

                printf "Entrando na pasta${GREEN} %s${ENDCOLOR}\n" "$opt"
                cd -- "$opt"
                break
                ;;
        esac
    done

}

select_game () {
# Exibe um menu para seleção de jogos pelo usuário.
    # Parâmetros:
    #   $1 - (string, referência) Nome do jogo selecionado (retorno)
    #   $2 - (string, referência) Caminho do arquivo do jogo selecionado (retorno)
    #   $@ - Lista de caminhos de arquivos de jogos disponíveis para seleção
    local -n selected_name="$1"
    local -n selected_path="$2"
    local -n map="$3"
    shift 3
       
    local opt=""
    local files_array=("$@")

    local file=""
    local game_names=()
    for file in "${files_array[@]}"; do
        game_names+=("${map[$file]}")
    done

    printf "${RED}Selecione um jogo:${ENDCOLOR}\n"
    select opt in "${game_names[@]}" "Sair"; do
        case "$opt" in
            "Sair")
                echo "Saindo..."
                exit 0
                ;;
            *)
                ! is_valid_option "$REPLY" "$#" && continue

                printf "Jogo selecionado: ${GREEN}%s${ENDCOLOR}\n" "$opt"
                selected_name="$opt"
                selected_path="${files_array[$REPLY-1]}"
                break
                ;;
        esac
    done

}

mv_xml_entry () {
    path=$1
    # arquivos temporários seguros
        TMP_GAME="$(mktemp --tmpdir game.XXXXXX.xml)"
        TMP_XSL="$(mktemp --tmpdir append.XXXXXX.xsl)"
        TMP_OUT="$(mktemp --tmpdir out.XXXXXX.xml)"

        # 1) extrai o <game> para o temporário
        xmlstarlet sel -t -c "//game[name='$SELECTED_GAME_NAME']" "./gamelist.xml" > $TMP_GAME

        # 2) cria o XSLT via heredoc
# Se der tab no heredoc, o XSLT fica inválido e apaga o gamelist.xml alvo
cat > "$TMP_XSL" <<'XSL'
<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
  <xsl:output method="xml" indent="yes"/>

  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="gameList">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
      <xsl:apply-templates select="document('%%TMP_GAME%%')/game"/>
    </xsl:copy>
  </xsl:template>

</xsl:stylesheet>
XSL

        # substitui o placeholder pelo caminho do arquivo temporário do jogo
        sed -i "s|%%TMP_GAME%%|$TMP_GAME|g" "$TMP_XSL"

        # 3) aplica o XSLT ao arquivo destino e grava em TMP_OUT
        xsltproc "$TMP_XSL" "$path" > "$TMP_OUT"

        # Apenas aproveita o arquivo temporário do jogo p/ formatar o XML de saída
        xmlstarlet fo -t --encode utf-8 $TMP_OUT > $TMP_GAME

        # 4) (opcional) backup do original
        #cp -a "$path" "${path}.bak.$(date +%s)"

        # 5) move o arquivo temporário formatado p/ o destino final
        printf "${GREEN}Atualizando gamelist.xml em %s${ENDCOLOR}\n" "$dest_path"
        sudo mv "$TMP_GAME" "$path" 2>/dev/null

        # 6) remove a entrada do gamelist.xml original
        printf "${RED}Removendo entrada do gamelist.xml original...${ENDCOLOR}\n"
        sudo xmlstarlet ed --inplace -d "//game[name='$SELECTED_GAME_NAME']" "./gamelist.xml"
}

mv_game () {
    local dest_path=""

    while true; do
        read -p "Digite o caminho de destino: " dest_path
        if [[ ! -d "$dest_path" ]]; then
            printf "${RED}Diretório não encontrado. Tente novamente.${ENDCOLOR}\n"
            continue
        fi

        break
    done

    local dest_xml="$dest_path/gamelist.xml"
    if [[ -f "$dest_xml" ]]; then
        printf "${YELLOW}Arquivo gamelist encontrado no destino...${ENDCOLOR}\n"

        mv_xml_entry "$dest_xml"

    else
        printf "${YELLOW}Nenhum gamelist.xml encontrado no destino. Criando um...${ENDCOLOR}\n"

        sudo touch "$dest_xml" 2>/dev/null
sudo tee "$dest_xml" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<gameList>
</gameList>
EOF

        mv_xml_entry "$dest_xml"

    fi
    printf "Movendo ${CYAN}%s${ENDCOLOR} para ${CYAN}%s${ENDCOLOR}\n" "$SELECTED_GAME_NAME" "$dest_path"
    sudo mv "$SELECTED_GAME_PATH" "$dest_path" 2>/dev/null
    printf "${GREEN}Jogo movido com sucesso!${ENDCOLOR}\n"

}

main () {
    local dirs_list=(*/) # Lista de pastas no diretório atual | antiga: DIRS=(*/)
    local dirs_with_games=() # antes: GAMES_DIRS=()
    local dirs_without_games=() # antes: NO_GAMES_DIRS=()
    local user_answer=""
    local games_files=()
    local games_only_in_xml=()
    local -A games_map # [chave/arquivo]=>[valor/nome do jogo]
    local selected_game_name=""
    local selected_game_path=""
    
    printf "Avaliando Diretório:${GREEN} %s${ENDCOLOR}\n" "${PWD##*/}"

                                        # Conta o número de linhas/elementos em dirs_list
    printf "${YELLOW}%s Pastas Encontradas${ENDCOLOR}\n" "$(printf '%s\n' "${dirs_list[@]}" | wc -l)"

    echo "Procurando por pastas contendo ROMs..."
    look4_roms dirs_list dirs_with_games dirs_without_games

    printf "${YELLOW}%s Pastas contendo ROMs${ENDCOLOR}\n" "${#dirs_with_games[@]}" 
    printf "${CYAN}%s Pastas possuem apenas "gamelist.xml"${ENDCOLOR}\n" "${#dirs_without_games[@]}" 

    ask_user user_answer "Ver pastas com ROMs" "Ver pastas sem ROMs" 
    if [[ "$user_answer" -eq 1 ]]; then
        select_dir "${dirs_with_games[@]}"

        get_files games_files
        printf "${YELLOW}%s Jogos Encontrados${ENDCOLOR}\n" "${#games_files[@]}"

        find_only_in_xml games_files games_only_in_xml games_map
        printf "${CYAN}%s Jogos estão apenas no gamelist.xml${ENDCOLOR}\n" "${#games_only_in_xml[@]}"

        ask_user user_answer "Ver jogos" "Editar gamelist.xml"

   #else # VOLTAR DEPOIS E TERMINAR ESSE CAMINHO
   #    select_dir "${dirs_without_games[@]}"
   fi
#
   #
   if [[ "$user_answer" -eq 1 ]]; then
       select_game selected_game_name selected_game_path games_map "${games_files[@]}" 

   #    while true; do
   #    ask_user "Mover jogo" "Copiar jogo" "Deletar jogo"
   #    case "$USER_ANSWER" in
   #            1)
   #                mv_game
   #                break
   #                ;;
   #            2)
   #               echo "Copiar jogo selecionado"
   #                break
   #                ;;
   #            3)
   #                echo "Deletar jogo selecionado"
   #                break
   #                ;;
   #            *)
   #                echo "Escolha uma ação válida."
   #                continue
   #                ;;
   #        esac
   #    done 
    fi

}
main "$@"