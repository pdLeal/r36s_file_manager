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
readonly EXTENSIONS=("nes" "smc" "sfc" "fig" "gb" "NES" "CSO" "gbsfc" "fig" "gb" "gbc" "gba" "bin" "cdi" "md" "smd" "gen" "sms" "gg" "n64" "z64" "v64" "s64" "iso" "cso" "cue" "pbp" "PBP" "pce" "gdi" "chd" "zip" "7z")


#####################################################
# FUNÇÕES
#####################################################

cleanup() {
    if [[ -n "${tmp_game:-}" ]]; then
    echo "Limpando arquivos temporários..."
    rm -f "$tmp_game" "$tmp_output_raw" "$tmp_xsl" "$tmp_output_fmt" 
    fi
}
trap cleanup EXIT 

#####################################################

look4_roms() {
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
        printf "${BLUE}$msg Tente Novamente${ENDCOLOR}\n"
        return 1  # Inválido
    else
        return 0  # Válido
    fi
}

ask_user() {
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

select_dir() {
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
        path="${path#./}"  # Remove o prefixo ./
        in_xml["$path"]="$name" 

    done < <(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "name" -n ./gamelist.xml | \
                sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')
        # Se ñ tratar os &...; o xmlstarlet retorna como $amp; e ñ bate com o nome do arquivo

    for file in "${files[@]}"; do
        if [[ -n "${in_xml["$file"]:-}" ]]; then
            map["$file"]="${in_xml["$file"]}"
            unset in_xml["$file"] # Como o arquivo existe, ñ faz sentido manter no only_in_xml
        fi
    done
    
}

select_game() {
# Exibe um menu para seleção de jogos pelo usuário.
    # Parâmetros:
    #   $1 - (string, referência) Variável para armazenar o nome do jogo selecionado
    #   $2 - (string, referência) Variável para armazenar o caminho do arquivo do jogo selecionado
    #   $3 - (associative array, referência) Mapa de arquivos para nomes de jogos
    local -n selected_name="$1"
    local -n selected_path="$2"
    local -n map="$3"
       
    local opt=""

    printf "${RED}Selecione um jogo:${ENDCOLOR}\n"
    select opt in "${map[@]}" "Sair"; do
        case "$opt" in
            "Sair")
                echo "Saindo..."
                exit 0
                ;;
            *)
                ! is_valid_option "$REPLY" "${#map[@]}" && continue

                selected_name="$opt"

                for file in "${!map[@]}"; do # Vale lembrar q a chave/arquivo é igual ao path do gamelist.xml
                    if [[ "${map[$file]}" == "$selected_name" ]]; then
                        selected_path="$file"
                        break
                    fi
                done

                printf "Jogo selecionado: ${GREEN}%s${ENDCOLOR}\n" "$selected_name"
                printf "Nome do arquivo selecionado: ${CYAN}%s${ENDCOLOR}\n" "$selected_path"
                ;;
        esac
        break
    done

}

create_gamelist() {
# Cria um gamelist.xml básico em um diretório especificado
    local target="$1"
    printf "Criando${GREEN} %s${ENDCOLOR}\n" "$target_file"

sudo tee "$target" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<gameList>
</gameList>
EOF
}

duplicate_xml_with_entry() {
# Cria uma cópia do gamelist.xml com a entrada de um jogo anexada como arquivo temporário
    local game="$1"
    local tgt_file="$2"
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
    xmlstarlet sel -t -c "//game[name='$game']" "./gamelist.xml" > "$tmp_game"

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
    xmlstarlet fo -t --encode utf-8 $tmp_output_raw > "$tmp_output_fmt"

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

    if ! sudo xmlstarlet ed --inplace -d "//game[name='$game']" "./gamelist.xml"; then
        printf "${BLUE}Erro ao remover a entrada do gamelist.xml. Verifique permissões ou integridade do arquivo.${ENDCOLOR}\n"
        exit 1
    else
        return 0
    fi
}

process_other_files() {
# Jogos podem conter arquivos relacionados como imgs ou videos ou nenhum
# É preciso descobrir se existem e move-los junto
   local game_xml="$1"
   local tg_dir="$2"
   local command="$3"
   printf "Verificando e movendo arquivos relacionados ao jogo... \n"

    # Extrai os valores dos elementos filhos do <game> que não sejam <path>, <name>, <desc>ou scrap
    # path e name já são utilizadas, desc pode conter texto longo e scrap aparece como se fosse arquivo - por isso foram excluídos
    local other_files=()
    mapfile -t other_files < <(xmlstarlet sel -t \
                    -m "//game/*[starts-with(normalize-space(.), \"./\") and \
                        not(self::name or self::path or self::desc or self::scrap)]" \
                    -v "." -n "$game_xml")

    if [[ "${#other_files[@]}" -eq 0 ]]; then
        printf "${CYAN}Nenhum arquivo relacionado encontrado.${ENDCOLOR}\n"
        return 0
    else

        local -A seen
        local unique=()
        local other=""

        for other in "${other_files[@]}"; do # Remove duplicatas, pois alguns jogos possuem duas ou mais
            if [[ -z "${seen[$other]:-}" ]]; then  # tags q apontam p/ mesmo arquivo
                seen[$other]=1
                unique+=("$other")
            fi
        done

        other_files=("${unique[@]}")


        printf "Foram encontrados ${GREEN}%s arquvios relacionados${ENDCOLOR}\n" "${#other_files[@]}"

        for other in "${other_files[@]}"; do

            local file_dir="${other%/*}" # Remove o nome do arquivo, ficando só com o diretório
            file_dir="${file_dir#./}" # Remove o prefixo ./

            local target_file_dir="$tg_dir/$file_dir"

            if [[ ! -d "$target_file_dir" ]]; then
                printf "${CYAN}Criando diretório %s${ENDCOLOR}\n" "$target_file_dir"
                sudo mkdir "$target_file_dir"
            fi
            printf "Movendo ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$other" "$target_file_dir"
            sudo "$command" "$other" "$target_file_dir"
            
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
        read -p "Digite o diretório de destino: " target_dir
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
        printf "${YELLOW}Entrada removida com sucesso!${ENDCOLOR}\n"

   
    process_other_files "$tmp_game" "$target_dir" "mv" #tmp_game é criado pelo mv_xml_entry
    
    printf "Movendo ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$selected_game" "$target_dir"
    sudo mv "$selected_path" "$target_dir" && \
        printf "${YELLOW}Jogo movido com sucesso!${ENDCOLOR}\n"

}

cp_game() {
# Copia um jogo e sua entrada no gamelist.xml para um diretório de destino.
    # Parâmetros:
    #   $1 - Nome do jogo
    #   $2 - Caminho do arquivo do jogo
    local game_name="$1"
    local game_path="$2"
    local target_dir=""

    while true; do
        read -p "Digite o diretório de destino: " target_dir
        if [[ ! -d "$target_dir" ]]; then
            printf "${BLUE}Diretório não encontrado. Tente novamente.${ENDCOLOR}\n"
            continue
        fi
        break
    done

    local target_file="$target_dir/gamelist.xml" 
    if [[ -f "$target_file" ]]; then
        printf "${YELLOW}Arquivo gamelist encontrado no destino...${ENDCOLOR}\n"
    else
        printf "${CYAN}Nenhum gamelist.xml encontrado no destino.${ENDCOLOR}\n"
        create_gamelist "$target_file"
    fi
    #duplicate_xml_with_entry "$game" "$target_file"
    #sudo mv "$tmp_output_fmt" "$target_file" 2>/dev/null

    printf "Verificando e movendo arquivos relacionados ao jogo... \n"
    process_other_files "$tmp_game" "$target_dir" "cp"
    
    printf "Copiando ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$game_name" "$target_dir"
    sudo cp "$game_path" "$target_dir" 
    printf "${YELLOW}Jogo copiado com sucesso!${ENDCOLOR}\n"

}

main() {
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

    echo "Procurando por pastas contendo ROMs..."
    look4_roms dirs_list dirs_with_games dirs_without_games

    printf "${YELLOW}%s Pastas contendo ROMs${ENDCOLOR}\n" "${#dirs_with_games[@]}" 
    printf "${CYAN}%s Pastas possuem apenas "gamelist.xml"${ENDCOLOR}\n" "${#dirs_without_games[@]}" 

    ask_user user_answer "Ver pastas com ROMs" "Ver pastas sem ROMs" 
    if [[ "$user_answer" -eq 1 ]]; then
        select_dir "${dirs_with_games[@]}"

        get_files game_files
        find_only_in_xml game_files games_only_in_xml file_by_game

        printf "${YELLOW}%s Jogos Encontrados${ENDCOLOR}\n" "${#file_by_game[@]}"
        printf "${CYAN}%s Jogos estão apenas no gamelist.xml${ENDCOLOR}\n" "${#games_only_in_xml[@]}"

        ask_user user_answer "Ver jogos" "Editar gamelist.xml"

   #else # VOLTAR DEPOIS E TERMINAR ESSE CAMINHO
   #    select_dir "${dirs_without_games[@]}"
   fi
#
   #
   if [[ "$user_answer" -eq 1 ]]; then
       select_game selected_game_name selected_game_path file_by_game 

       while true; do
       ask_user user_answer "Mover jogo" "Copiar jogo" "Deletar jogo"
       case "$user_answer" in
               1)
                   mv_game "$selected_game_name" "$selected_game_path"
                   break
                   ;;
               2)
                   cp_game "$selected_game_name" "$selected_game_path"
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