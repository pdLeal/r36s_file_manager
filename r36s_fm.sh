#!/usr/bin/env bash
# r36s_fm.sh - Gerenciador de arquivos de jogos para R36s
# Autor: pleal
# Data de Início: 18/10/2025

# shellcheck disable=SC2059
set -u
#####################################################
# VARIÁVEIS GLOBAIS E CONSTANTES
#####################################################

# Cores para saída no terminal
readonly RED="\033[31m"
readonly GREEN="\033[32m"
readonly YELLOW="\033[33m"
readonly BLUE="\033[34m"
readonly PINK="\033[35m"
readonly CYAN="\033[36m"
readonly ENDCOLOR="\033[0m"

# Extensões de arquivos de jogos suportadas
readonly EXTENSIONS=("nes" "smc" "sfc" "fig" "gb" "NES" "CSO" "gbsfc" "fig" "gb" "gbc" "gba" "bin" "cdi" "md" "smd" "gen" "sms" "gg" "n64" "z64" "v64" "s64" "iso" "cso" "cue" "pbp" "PBP" "pce" "gdi" "chd" "zip" "7z")


#####################################################
# FUNÇÕES
#####################################################

cleanup() {
    if [[ -n "${tmp_game:-}" ]]; then
    echo "Limpando arquivos temporários..."
    rm -f "${tmp_game:-}" "${tmp_output_raw:-}" "${tmp_xsl:-}" "${tmp_output_fmt:-}"
    fi
}
trap cleanup EXIT 2>/dev/null

#####################################################

look4_roms() {
# Procura por arquivos de jogos nas pastas fornecidas
    local -n dirs=$1
    local -n w_games=$2
    local -n w_no_games=$3
    w_games=()
    w_no_games=()

    #local first=1 # flag para a primeira iteração
    local ext=""
    local ext_find=()

    # Converte EXTENSIONS na string "-name '*.nes' -o -name '*.chd' -o -name '*.zip'" p/ ser usado no find
    
    for ext in "${EXTENSIONS[@]}"; do
        if (( ${#ext_find[@]} == 0 )); then
        # Se for a primeira iteração/array vazio
            ext_find+=(-name "*.${ext}")
        else
            ext_find+=(-o -name "*.${ext}")
        fi
    done


    # Checa se existe ao menos um arquivo chamado "gamelist.xml" em $dir.
    # Se existir, find imprime o diretório pai (%h) e a condição [-n ...] será verdadeira.
    for dir in "${dirs[@]}"; do
        if [ -n "$(find "$dir" -type f -name "gamelist.xml" -printf '%h\n')" ]; then
            # Procura por pelo menos 1 arquivo com as extensões especificadas e popula os arrays correspondentes
            if find "$dir" -type f \( "${ext_find[@]}" \) -print -quit| grep -q .; then
                w_games+=("$dir")
            else
        # OBS: só procura em dirs com gamelist.xml - PENSAR SOBRE OS DIRS SEM ELE DEPOIS
                w_no_games+=("$dir")
            fi
            
        fi
    done
}

is_valid_option() {
# Verifica se a entrada é um número, se ñ é < 1 ou > q o número de opções/argumentos 
    local input="$1"
    local max_option="$2"
    local msg="${3:-"Opção inválida."}"

    if [[ ! "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 ]] || [[ "$input" -gt "$max_option" ]]; then
        printf "${BLUE}%s Tente Novamente${ENDCOLOR}\n" "$msg"
        return 1  # Inválido
    else
        return 0  # Válido
    fi
}

ask_user() {
# Exibe um menu de opções para o usuário e armazena a escolha em user_answer
    local question="${1:-"O que deseja fazer?"}"
    local -n answer="$2"
    shift 2 
    local opt=""

    printf "\n${RED}%s${ENDCOLOR}\n" "$question"
    select opt in "$@" "Sair"; do
        case "$opt" in
            "Sair")
                echo "Saindo..."
                exit 0
                ;;
            *)
                ! is_valid_option "$REPLY" "$#" && continue # pula para próxima iteração se a opção fornecida for inválida
                
                # shellcheck disable=SC2034
                answer="$opt"
                break
                ;;
        esac
    done

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
    #   $2 - (associative array, referência) Mapa para armazenar jogos apenas no XML
    #   $3 - (associative array, referência) Mapa para armazenar arquivos encontrados com seus nomes de jogos
    local -n files="$1"
    local -n in_xml="$2"
    local -n map="$3"
    local file=""
    
    # Verificar cada jogo do XML
    local path=""
    local name=""
    while IFS='|' read -r path name; do
    # Armazena todas as entradas arquivo/jogo do XML
        path="${path#./}"  # Remove o prefixo ./
        in_xml["$path"]="$name" 
    done < <(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "name" -n ./gamelist.xml | \
                sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')
        # Se ñ tratar os &...; o xmlstarlet retorna como $amp; e ñ bate com o nome do arquivo

    for file in "${files[@]}"; do
        if [[ -n "${in_xml["$file"]:-}" ]]; then
            # shellcheck disable=SC2034
            map["$file"]="${in_xml["$file"]}"
            unset "${in_xml["$file"]}" # Como o arquivo existe, ñ faz sentido manter no only_in_xml
        fi
    done
    
}

create_gamelist() {
# Cria um gamelist.xml básico em um diretório especificado
    local target="$1"
    printf "Criando${GREEN} %s${ENDCOLOR}\n" "$target"

sudo tee "$target" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<gameList>
</gameList>
EOF
}

escape_xpath_string() {
# Se não escapar corretamente, jogos como NFL' 95 quebram o XPath
    local s="$1"
    if [[ "$s" == *"'"* ]]; then
        # Divide por aspas simples e concatena
        local parts=()
        IFS="'" read -ra chunks <<< "$s"
        for i in "${!chunks[@]}"; do
            parts+=("'${chunks[$i]}'")
            # Insere o caractere de aspas entre partes (menos depois da última)
            if [[ $i -lt $((${#chunks[@]} - 1)) ]]; then
                parts+=("\"'\"")
            fi
        done
        printf "concat(%s)" "$(IFS=','; echo "${parts[*]}")"
    else
        printf "'%s'" "$s"
    fi
}

duplicate_xml_with_entry() {
# Cria uma cópia do gamelist.xml com a entrada de um jogo anexada como arquivo temporário
    local game="$1"
    local tgt_file="$2"
    local open_vscode="${3:-false}" # flag q controla a edição de metadados
    printf "Criando arquivos temporários necessários...\n"

    # Arquivos temporários seguros
    tmp_game="$(mktemp --tmpdir game.XXXXXX.xml)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_game"

    tmp_xsl="$(mktemp --tmpdir append.XXXXXX.xsl)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_xsl"

    tmp_output_raw="$(mktemp --tmpdir out_raw.XXXXXX.xml)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_output_raw"

    tmp_output_fmt="$(mktemp --tmpdir out_fmt.XXXXXX.xml)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_output_fmt"

    # 1) Extrai o <game> para o temporário
    printf "Extraindo entrada do jogo selecionado...\n"

    local safe_xpath
    safe_xpath=$(escape_xpath_string "$game")
    xmlstarlet sel -t -c "//game[name=$safe_xpath]" "./gamelist.xml" > "$tmp_game"

    if "$open_vscode"; then
        code --wait "$tmp_game"
    fi

    printf "Criando cópia do gamelist.xml de destino com a entrada anexada...\n"
    # 2) cria o XSLT via heredoc
# AVISO: Se der tab no heredoc, o XSLT fica inválido e apaga o gamelist.xml alvo !!!
cat > "$tmp_xsl" <<'XSL'
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
      <xsl:apply-templates select="document('%%tmp_game%%')/game"/>
    </xsl:copy>
  </xsl:template>

</xsl:stylesheet>
XSL

    # 2.1) Substitui o placeholder pelo caminho do arquivo temporário do jogo
    sed -i "s|%%tmp_game%%|$tmp_game|g" "$tmp_xsl"

    # 3) Aplica o XSLT ao arquivo destino e grava em tmp_output_raw

    xsltproc "$tmp_xsl" "$tgt_file" > "$tmp_output_raw"

    # 4) Formata o XML de saída corretamente
    xmlstarlet fo -t --encode utf-8 "$tmp_output_raw" > "$tmp_output_fmt"

    # 5) (opcional) backup do original
    #cp -a "$tgt_file" "${tgt_file}.bak.$(date +%s)" 

    # 6) Valida o XML final
    if xmlstarlet val -q "$tmp_output_fmt"; then
        return 0
    else
        printf "${BLUE}Erro: O arquivo temporário não é um XML válido. Operação Cancelada.${ENDCOLOR}\n"
        exit 1
    fi
    
}

mv_xml_entry() {
# Move a entrada do gamelist.xml temporário para o arquivo de destino
    local tgt_file="$1"
    
    # TODO: Lidar com erro de permissão ao invés de ignorar - eventualmente =)
    if sudo mv "$tmp_output_fmt" "$tgt_file" 2>/dev/null; then
        return 0
    else
        printf "${BLUE}Erro ao mover o arquivo temporário para o destino. Verifique permissões.${ENDCOLOR}\n"
        exit 1
    fi
}

rm_xml_entry() {
# Remove a entrada do gamelist.xml original
    local game="$1"
    printf "${CYAN}Removendo entrada do gamelist.xml...${ENDCOLOR}\n"

    
    local safe_xpath
    safe_xpath=$(escape_xpath_string "$game")    

    if sudo xmlstarlet ed --inplace -d "(//game[name=$safe_xpath])[1]" "./gamelist.xml"; then
        return 0
    else
        printf "${BLUE}Erro ao remover a entrada do gamelist.xml. Verifique permissões ou integridade do arquivo.${ENDCOLOR}\n"
        exit 1
    fi
}

process_other_files() {
# Jogos podem conter arquivos relacionados como imgs ou videos ou nenhum
# É preciso descobrir se existem e move-los junto
   local game_xml="$1"
   local tg_dir="$2"
   local command="$3"
   printf "Verificando e processando arquivos relacionados ao jogo... \n"

    # Extrai os valores dos elementos filhos do <game> que não sejam <path>, <name>, <desc>ou scrap
    # path e name já são utilizadas, desc pode conter texto longo e scrap aparece como se fosse arquivo - por isso foram excluídos
    local other_files=()
    local file=""

    mapfile -t other_files < <(xmlstarlet sel -t \
                    -m "//game/*[starts-with(normalize-space(.), \"./\") and \
                        not(self::name or self::path or self::desc or self::scrap)]" \
                    -v "." -n "$game_xml")

    
    # TODO: passar selected_game_path EXPLICITAMENTE!!!
    # Alguns jogos possuem arquivos como fileName.iso e fileName.cue q devem ser processados tbm
    local name="${selected_game_path%.*}"
    mapfile -t -O "${#other_files[@]}" other_files < <(find . -type f -name "$name.*")
    
    if [[ "${#other_files[@]}" -eq 0 ]]; then
        printf "${CYAN}Nenhum arquivo relacionado encontrado.${ENDCOLOR}\n"
        return 0
    else

        local -A seen
        local unique=()
        local other=""

        for other in "${other_files[@]}"; do
        # Remove duplicatas, pois alguns jogos possuem duas ou mais tags q apontam p/ mesmo arquivo ou foram achados novamente pelo segundo mapfile
        # Tbm checa se o arquivo realmente existe, pq né, num vai processar oq ñ tá lá =)
            if [[ -z "${seen[$other]:-}" ]] && [[ "$other" != "./$selected_game_path" ]] && [[ -e "$other" ]]; then
                seen[$other]=1                         
                unique+=("$other")
            fi
        done

        other_files=("${unique[@]}")

        printf "Foram encontrados ${GREEN}%s arquvios relacionados${ENDCOLOR}\n" "${#other_files[@]}"
        printf "${PINK}%s${ENDCOLOR}\n" "${other_files[@]}"

        for other in "${other_files[@]}"; do

            local sub_dir="${other%/*}" # Remove o nome do arquivo, ficando só com o diretório
            sub_dir="${sub_dir#./}" # Remove o prefixo ./

            local target_sub_dir=""
            
            if [[  "$sub_dir" =~ ^\. ]]; then # Decide entre usar o diretório principal como destino ou um subdiretório
                target_sub_dir="$tg_dir"
            else
                target_sub_dir="$tg_dir/$sub_dir"
            fi
                
            case "$command" in
                cp|mv)
                    if [[ ! -d "$target_sub_dir" ]]; then
                        printf "${CYAN}Criando diretório %s${ENDCOLOR}\n" "$target_sub_dir"
                        sudo mkdir -p "$target_sub_dir"
                    fi
                    ;;&
                mv)
                    
                    printf "Movendo ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$other" "$target_sub_dir"
                    sudo "$command" "$other" "$target_sub_dir"
                    continue
                    ;;
                cp)
                    
                    printf "Copiando ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$other" "$target_sub_dir"
                    sudo "$command" "$other" "$target_sub_dir"
                    continue
                    ;;
                rm)
                    
                    printf "Removendo ${GREEN}%s${ENDCOLOR}${ENDCOLOR}\n" "$other"
                    sudo "$command" "$other"
                    continue
                    ;;
            esac
            
        done

        printf "${YELLOW}Arquivos relacionados processados com sucesso!${ENDCOLOR}\n"
        return 0
    fi


}

mv_game() {
# Move um jogo e sua entrada no gamelist.xml para um diretório de destino.
    # Parâmetros:
    #   $1 - Nome do jogo
    #   $2 - Caminho do arquivo do jogo
    local selected_game="$1"
    local selected_path="$2"
    local target_dir=""

    while true; do
        read -r -p "Digite o diretório de destino: " target_dir
        if [[ ! -d "$target_dir" ]]; then
            printf "${BLUE}Diretório não encontrado. Tente novamente.${ENDCOLOR}\n"
            continue
        fi
        break
    done

    local target_file="$target_dir/gamelist.xml" # gamelist.xml no diretório de destino
    if [[ -f "$target_file" ]]; then
        printf "${YELLOW}Arquivo gamelist encontrado no destino...${ENDCOLOR}\n"
    else
        printf "${CYAN}Nenhum gamelist.xml encontrado no destino.${ENDCOLOR}\n"
        create_gamelist "$target_file"
    fi

    duplicate_xml_with_entry "$selected_game" "$target_file" && \
        printf "${GREEN}Arquivo temporário validado com sucesso!${ENDCOLOR}\n"
        
    mv_xml_entry "$target_file" && \
        printf "${YELLOW}Entrada movida com sucesso para %s${ENDCOLOR}\n" "$target_file"

    rm_xml_entry "$selected_game" && \
        printf "${YELLOW}Entrada removida do arquivo de origem com sucesso!${ENDCOLOR}\n"

   
    process_other_files "$tmp_game" "$target_dir" "mv" #tmp_game é criado pelo duplicate_xml...
    
    printf "Movendo ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$selected_game" "$target_dir"
    sudo mv "$selected_path" "$target_dir" && \
        printf "${YELLOW}Jogo movido com sucesso!${ENDCOLOR}\n"
    # rsync -ah --info=progress2 --remove-source-files "$selected_path" "$target_dir/"
    # Dá p/ usar o comando acima - mais seguro - porém deu problema devido a espaço de armazenamento
    # Resolver eventualmente =)

}

cp_game() {
# Copia um jogo e sua entrada no gamelist.xml para um diretório de destino.
    # Parâmetros:
    #   $1 - Nome do jogo
    #   $2 - Caminho do arquivo do jogo
    local selected_game="$1"
    local selected_path="$2"
    local target_dir=""

    while true; do
        read -r -p "Digite o diretório de destino: " target_dir
        if [[ ! -d "$target_dir" ]]; then
            printf "${BLUE}Diretório não encontrado. Tente novamente.${ENDCOLOR}\n"
            continue
        fi
        break
    done

    local target_file="$target_dir/gamelist.xml" # gamelist.xml no diretório de destino
    if [[ -f "$target_file" ]]; then
        printf "${YELLOW}Arquivo gamelist encontrado no destino...${ENDCOLOR}\n"
    else
        printf "${CYAN}Nenhum gamelist.xml encontrado no destino.${ENDCOLOR}\n"
        create_gamelist "$target_file"
    fi

    duplicate_xml_with_entry "$selected_game" "$target_file" && \
        printf "${GREEN}Arquivo temporário validado com sucesso!${ENDCOLOR}\n"
        
    mv_xml_entry "$target_file" && \
        printf "${YELLOW}Entrada movida com sucesso para %s${ENDCOLOR}\n" "$target_file"

    process_other_files "$tmp_game" "$target_dir" "cp" #tmp_game é criado pelo mv_xml_entry
    
    printf "Copiando ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$selected_game" "$target_dir"  
    sudo rsync -ah --info=progress2 "./$selected_path" "$target_dir/" && \
        printf "${YELLOW}Jogo Copiado com sucesso!${ENDCOLOR}\n"

}

rm_game() {
# Remove um jogo e sua entrada no gamelist.xml.
    # Parâmetros:
    #   $1 - Nome do jogo
    #   $2 - Caminho do arquivo do jogo
    local selected_game="$1"
    local selected_path="$2"

    printf "Criando xml temporário...\n"
    tmp_game="$(mktemp --tmpdir game.XXXXXX.xml)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_game"

    printf "Extraindo entrada do jogo selecionado...\n"

    local safe_xpath
    safe_xpath=$(escape_xpath_string "$selected_game")
    xmlstarlet sel -t -c "//game[name=$safe_xpath]" "./gamelist.xml" > "$tmp_game"

    rm_xml_entry "$selected_game" && \
        printf "${YELLOW}Entrada removida com sucesso!${ENDCOLOR}\n"

    process_other_files "$tmp_game" "$selected_path" "rm"

    sudo rm -f "$selected_path" && \
        printf "${YELLOW}Jogo removido com sucesso!${ENDCOLOR}\n"

    rm -f "$tmp_game" && \
        printf "${YELLOW}Arquivo temporário removido com sucesso!${ENDCOLOR}\n"
}

show_game_metadata() {
    local game="$1"
    printf "\nDados sobre: ${GREEN}%s${ENDCOLOR}\n" "$game"
    
    local safe_xpath
    safe_xpath=$(escape_xpath_string "$game")
    xmlstarlet sel -t -m "//game[name=$safe_xpath]" -m "*" \
    -v "name()" -o ": " -v "normalize-space(.)" -n -b ./gamelist.xml \
    | awk -v C="${PINK}" -v E="${ENDCOLOR}" -F':' '{ 
    gsub(/&amp;/, "\\&", $2)
    gsub(/&lt;/, "<", $2)
    gsub(/&gt;/, ">", $2)
    gsub(/&quot;/, "\"", $2)
    gsub(/&#39;/, "'\''", $2)
    print C $1 E ": " $2 
    }'
    return 0

}

edit_metadata() {
    local game="$1"

    duplicate_xml_with_entry "$game" "./gamelist.xml" "true" && \
        printf "${YELLOW}Arquivo temporário validado com sucesso!${ENDCOLOR}\n"

    mv_xml_entry "./gamelist.xml" && \
        printf "${YELLOW}Entrada atualizada com sucesso!${ENDCOLOR}\n"
    
    rm_xml_entry "$game" && \
        printf "${YELLOW}Entrada removida do arquivo de origem com sucesso!${ENDCOLOR}\n"    

}

show_gamelist_data() {
    xmlstarlet sel -t -m "//game/*" -v "name()" -o ": " -v "normalize-space(.)" -n ./gamelist.xml \
    | awk -v C="${PINK}" -v E="${ENDCOLOR}" -F':' '
    BEGIN { game_num = 0 }
    $1 == "path" && NR > 0 { print "\n--- ENTRADA " ++game_num " ---" }
    { 
        gsub(/&amp;/, "\\&", $2)
        gsub(/&lt;/, "<", $2)
        gsub(/&gt;/, ">", $2)
        gsub(/&quot;/, "\"", $2)
        gsub(/&#39;/, "'\''", $2)
        print C $1 E ": " $2 
    }'
    return 0

}


STATE="LOOK"
main_menu() {
    local dirs_list=(*/) # Lista de pastas no diretório atual
    local dirs_with_games=() 
    local dirs_without_games=() 
    local user_answer=""
    local game_files=()
    local -A file_by_game # [chave/arquivo]=>[valor/nome do jogo]
    local -A games_only_in_xml
    local selected_game_name=""
    local selected_game_path=""
    
    printf "Avaliando Diretório:${GREEN} %s${ENDCOLOR}\n" "${PWD##*/}"
    printf "${YELLOW}%s Pastas Encontradas${ENDCOLOR}\n" "${#dirs_list[@]}"

    while true; do
        case "$STATE" in
            "LOOK")
                echo "Procurando por pastas contendo ROMs..."
                look4_roms dirs_list dirs_with_games dirs_without_games

                printf "${YELLOW}%s Pastas contendo ROMs${ENDCOLOR}\n" "${#dirs_with_games[@]}" 
                printf "${CYAN}%s Pastas possuem apenas 'gamelist.xml'${ENDCOLOR}\n" "${#dirs_without_games[@]}" 

                ask_user "" user_answer "Ver pastas com ROMs" "Ver pastas sem ROMs"
                case "$user_answer" in 
                    "Ver pastas com ROMs")
                        dirs_to_look=("${dirs_with_games[@]}")
                        ;;
                    "Ver pastas sem ROMs")
                        dirs_to_look=("${dirs_without_games[@]}")
                        ;;
                esac    
                
                STATE="CONSOLE_MENU"
                ;;

            "CONSOLE_MENU")
                ask_user "Selecione uma pasta:" user_answer "${dirs_to_look[@]}" "Voltar"
                case "$user_answer" in
                        "Voltar")
                            STATE="LOOK"
                            ;;

                        *)
                            printf "Entrando na pasta${GREEN} %s${ENDCOLOR}\n" "$user_answer"
                            cd -- "$user_answer" || exit 1
                            STATE="DIR_ACTION"
                            ;;

                    esac
                ;;

            "DIR_ACTION")
                # Reinicia os arrays p/ evitar bug de duplicar/acumular jogos/arquivos
                # shellcheck disable=SC2034
                game_files=()
                file_by_game=()
                games_only_in_xml=()

                get_files game_files
                find_only_in_xml game_files games_only_in_xml file_by_game

                printf "${YELLOW}%s Jogos Encontrados${ENDCOLOR}\n" "${#file_by_game[@]}"
                printf "${CYAN}%s Jogos estão apenas no gamelist.xml${ENDCOLOR}\n" "${#games_only_in_xml[@]}"

                ask_user "" user_answer "Ver jogos" "Editar gamelist.xml" "Voltar"
                case "$user_answer" in
                    "Ver jogos")
                        STATE="GAMES_MENU"
                        ;;
                
                    "Editar gamelist.xml")
                        STATE="GAMELIST_MENU"
                        ;;
                    "Voltar") 
                        printf "Voltando p/ ${GREEN}%s${ENDCOLOR}\n" "$OLDPWD"
                        cd "$OLDPWD" || exit 1
                        STATE="CONSOLE_MENU"
                        ;;

                esac
                ;;

            "GAMES_MENU")
                ask_user "Selecione um jogo:" user_answer "${file_by_game[@]}" "Voltar"
                case "$user_answer" in
                    "Voltar")
                        STATE="DIR_ACTION"
                        ;;

                    *)
                        selected_game_name="$user_answer"

                        for file in "${!file_by_game[@]}"; do # Vale lembrar q a chave/arquivo é igual ao path do gamelist.xml
                            if [[ "${file_by_game[$file]}" == "$selected_game_name" ]]; then
                                selected_game_path="$file"
                                break
                            fi
                        done

                        printf "Jogo selecionado: ${GREEN}%s${ENDCOLOR}\n" "$selected_game_name"
                        printf "Arquivo selecionado: ${CYAN}%s${ENDCOLOR}\n" "$selected_game_path"
                        STATE="GAME_ACTION"
                        ;;

                esac
                ;;

            "GAME_ACTION")
                ask_user "" user_answer "Ver metadados" "Editar metadados" "Mover jogo" "Copiar jogo" "Deletar jogo" "Voltar"
                case "$user_answer" in
                        "Ver metadados")
                            show_game_metadata "$selected_game_name"
                            STATE="GAME_ACTION"
                            ;;

                        "Editar metadados")
                            edit_metadata "$selected_game_name"
                            STATE="DIR_ACTION"
                            ;;

                        "Mover jogo")
                            mv_game "$selected_game_name" "$selected_game_path"
                            STATE="DIR_ACTION"
                            ;;

                        "Copiar jogo")
                            cp_game "$selected_game_name" "$selected_game_path"
                            STATE="DIR_ACTION"
                            ;;

                        "Deletar jogo")
                            rm_game "$selected_game_name" "$selected_game_path"
                            STATE="DIR_ACTION"
                            ;;

                        "Voltar")
                            STATE="GAMES_MENU"
                            ;;

                    esac
                ;;

            "GAMELIST_MENU")
                ask_user "" user_answer "Usar VS Code" "Ver Entradas" "Deletar gamelist.xml" "Voltar"
                case "$user_answer" in
                        "Usar VS Code")
                            code --wait ./gamelist.xml \
                                && printf "${YELLOW}Entrada atualizada com sucesso!${ENDCOLOR}\n"
                            STATE="GAMELIST_MENU"
                            ;;

                        "Ver Entradas")
                            show_gamelist_data
                            STATE="GAMELIST_MENU"
                            ;;

                        "Deletar gamelist.xml")
                            echo "sudo rm ./gamelist.xml"
                            STATE="GAMELIST_MENU"
                            ;;

                        "Voltar")
                            STATE="DIR_ACTION"                        
                            ;;

                    esac
        esac
    done

}
main_menu "$@"