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
readonly -A EXTENSIONS=(
  ["nes"]=1
  ["NES"]=1
  ["smc"]=1
  ["sfc"]=1
  ["fig"]=1
  ["gb"]=1
  ["gbc"]=1
  ["gba"]=1
  ["bin"]=1
  ["cdi"]=1
  ["md"]=1
  ["smd"]=1
  ["gen"]=1
  ["sms"]=1
  ["gg"]=1
  ["n64"]=1
  ["z64"]=1
  ["v64"]=1
  ["s64"]=1
  ["iso"]=1
  ["cso"]=1
  ["cue"]=1
  ["pbp"]=1
  ["PBP"]=1
  ["pce"]=1
  ["gdi"]=1
  ["chd"]=1
  ["zip"]=1
  ["7z"]=1
  ["nds"]=1
  ["img"]=1
  ["ccd"]=1
  ["m3u"]=1
  ["wolf"]=1
) # Deveriam ser normalizadas ao invés de hardcoded upper and lower case, but today is not the day!

# AUX_EXTENSIONS=(
    #     "srm"
    #     "sav"
    #     "state"
    #     "nv"
    #     "cfg"
    #     "txt"
    #     "pdf"
# ) # Inutilizada por enquanto, mas acho q pode ser útil depois


cleanup() {
    if [[ -n "${tmp_game:-}" ]]; then
    echo "Limpando arquivos temporários..."
    rm -f "${tmp_game:-}" "${tmp_output_raw:-}" "${tmp_xsl:-}" "${tmp_output_fmt:-}"
    fi
}
trap cleanup EXIT 2>/dev/null

#####################################################


##############################################################################################################################
load_systems_info() {
    local -n system_paths_ref="$1"
    local -n valid_extensions_ref="$2"
    local -n valid_system_extensions_ref="$3"
    local -n systems_by_extension_ref="$4"

    local config_file=""
    local system_path="" system_name="" extensions=""
    local extensions_list=()
    local extension=""

    config_file="$(sudo find ../. -type f \( -name "es_systems.cfg" -o -name "es_systems.xml" \))"

    while IFS='|' read -r system_path system_name extensions; do
        system_paths_ref["$system_name"]="$system_path"

        read -ra extensions_list <<< "$extensions"

        for extension in "${extensions_list[@]}"; do
            # Set: sistema + extensão
            valid_system_extensions_ref["$system_name:$extension"]=1

            # Índice invertido: extensão -> sistemas
            if [[ -z "${systems_by_extension_ref["$extension"]:-}" ]]; then
                systems_by_extension_ref["$extension"]="$system_name"
                valid_extensions_ref["$extension"]=1

            else
                systems_by_extension_ref["$extension"]+="|$system_name"
            fi
        done

    done < <(
        sed 's/&\([^a-zA-Z#]\)/\&amp;\1/g' "$config_file" |
        sudo xmlstarlet sel -t \
            -m "//system" \
            -v "path" -o "|" \
            -v "name" -o "|" \
            -v "extension" \
            -n - |
        sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')
        # Primeiro "sed" pré-escapa '&' cru (ex.: "2>&1" dentro de <command>) que não faz parte de
        # uma entidade XML válida (&amp; &lt; etc.), pois o xmlstarlet falha ao
        # parsear XML malformado com '&' solto no meio do texto.


    ###########################################
    # DEBUG - Sistema -> Path
    ##########################################

    # printf "\n=== SYSTEM PATHS ===\n\n"

    # for name in "${!system_paths_ref[@]}"; do
    #     printf "%-15s -> %s\n" "$name" "${system_paths_ref["$name"]}"
    # done | sort -f

    # ###########################################
    # # DEBUG - Set (Sistema + Extensão)
    # ###########################################

    # printf "\n=== VALID SYSTEM EXTENSIONS ===\n\n"

    # for key in "${!valid_system_extensions_ref[@]}"; do
    #     printf "%-30s -> %s\n" \
    #         "$key" \
    #         "${valid_system_extensions_ref["$key"]}"
    # done | sort -f

    # ###########################################
    # # DEBUG - Índice invertido
    # ###########################################

    # printf "\n=== EXTENSION TO SYSTEM ===\n\n"

    # for extension in "${!systems_by_extension_ref[@]}"; do
    #     printf "%-10s -> %s\n" \
    #         "$extension" \
    #         "${systems_by_extension_ref["$extension"]}"
    # done | sort -f

    # printf "\n=== VALID EXTENSION ===\n\n"

    # for extension in "${!valid_extensions[@]}"; do
    #     printf "%-10s -> %s\n" \
    #         "$extension" \
    #         "${valid_extensions["$extension"]}"
    # done | sort -f

    # exit
}



##############################################################################################################################

dir_has_gamelist() {
# Checa se existe ao menos um arquivo chamado "gamelist.xml" em $dir.
    # Se existir, a condição [-n ...] será verdadeira.
    local dir="$1"
    [ -n "$(find "$dir" -type f -name "gamelist.xml" -print -quit)" ] && return 0
    return 1

}


classify_dirs_by_roms() {
# Procura por arquivos de jogos nas pastas fornecidas
    local -n dirs="$1"
    local -n w_games="$2"
    local -n w_no_games="$3"
    w_games=()
    w_no_games=()

    local ext=""
    local ext_find=()
    local dir=""

    # Converte valid_extensions na string "-name '*.nes' -o -name '*.chd' -o -name '*.zip'" p/ ser usado no find
    
    for ext in "${!valid_extensions[@]}"; do
        if (( ${#ext_find[@]} == 0 )); then
        # Se for a primeira iteração/array vazio
            ext_find+=(-name "*.${ext}")
        else
            ext_find+=(-o -name "*.${ext}")
        fi
    done

    for dir in "${dirs[@]}"; do
        if dir_has_gamelist "$dir"; then
            # Procura por pelo menos 1 arquivo com as extensões especificadas e popula os arrays correspondentes
            if [ -n "$(find "$dir" -type f \( "${ext_find[@]}" \) -print -quit)" ]; then
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

sort_games() {
# Orndena os jogos alfabeticamente
    local -n sorted="$1"
    shift 1
    mapfile -t sorted < <( printf "%s\n" "$@" | sort -f )
}

ask_user() {
# Exibe um menu de opções para o usuário e armazena a escolha em user_answer
    local question="${1:-"O que deseja fazer?"}"
    local -n answer="$2"
    shift 2
    local options=() 
    local opt=""

    options=( "$@" )

    printf "\n${RED}%s${ENDCOLOR}\n" "$question"
    select opt in "${options[@]}" "Sair"; do
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

compare_sizes() {
# Para jogos com arquivos de msm nome, mas extensões diferentes, determina qual o principal com base no tamanho 
    local prev_size
    local curr_size
    
    if [[ -z "${uniques[$name_without_extension]:-}" ]]; then
        uniques["$name_without_extension"]="$file"
        files_size["$file"]=$(stat -c %s "$file" 2>/dev/null || echo 0)
        # Se a chave ñ existe, o arquivo atual se torna o primeiro valor e seu tamanho é armazenado
    else
        local current_file_size=$(stat -c %s "$file")
        local prev_file="${uniques["$name_without_extension"]}"
        # Se existe, o tamanho do arquivo atual é calculado e o anterior é recuperado

        if [[ $current_file_size -gt ${files_size["$prev_file"]:-} ]]; then
            uniques["$name_without_extension"]="$file"
            files_size["$file"]="$current_file_size"
            # Os tamanhos dos arquivos são então comparados e o maior é mantido

        fi

    fi
}

# get_all_files() {
    # # Coleta todos os arquivos com as extensões especificadas e popula o array fornecido
    #     shopt -s globstar nullglob
    #     local -n found="$1"

    #     local ext=""
    #     local file=""

    #     for ext in "${valid_extensions[@]}"; do
    #         for file in **/*."$ext"; do # glob expansion responsável pela busca
    #             found["./$file"]=1
            
    #         done
        
    #     done

    #     shopt -u globstar nullglob
# }

get_all_files() {
    shopt -s globstar nullglob
    local -n unclassified_files_ref="$1"

    local file=""

    for file in **/*; do # glob expansion responsável por buscar recursivamente
        if [[ -f "$file" ]];then # -f veririfca se de fato é um arquivo válido
            unclassified_files_ref["./$file"]=1
        fi
    done

    shopt -u globstar nullglob
}

# load_xml_entries() {
    #     # Verifica cada entrada do gamelist.xml no diretório atual e armazena os campos path/name
    #     local -n entries="$1"
    #     local path=""
    #     local name=""

    #     while IFS='|' read -r path name; do
    #         entries["$path"]="$name"

    #     done < <(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "name" -n ./gamelist.xml | \
    #                 sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')
    #         # Se ñ tratar os &...; o xmlstarlet retorna como $amp; e ñ bate com o nome do arquivo
    
# }

load_xml_entries() {
    # Verifica cada entrada do gamelist.xml no diretório atual e armazena os campos path/name
    local -n xml_unclassified_entries_ref="$1"
    local -n unclassified_images_ref="$2"
    local -n unclassified_videos_ref="$3"
    local -n unclassified_marquees_ref="$4"
    local -n unclassified_thumbnails_ref="$5"

    local path=""
    local name=""
    local image=""
    local video=""
    local marquee=""
    local thumbnail=""

    while IFS='|' read -r path name image video marquee thumbnail; do
        # a tag <image /> aparece vez ou outra e quebra o parse do xmlstarlet,
        # oq gera uma iteração do loop com todos os valores vazios
        # poderia só encerraar a iteração, mas podem haver caso em q
        # a tag path é vazia, mas outras não
        [[ -n "$path" ]] && xml_unclassified_entries_ref["$path"]="$name"
        
        # as vezes a tag ñ existe ou está vazia, nesses caso ñ é preciso perder tempo armazenando ""
        [[ -n "$image" ]] && unclassified_images_ref["$path"]="$image"
        [[ -n "$video" ]] && unclassified_videos_ref["$path"]="$video"
        [[ -n "$marquee" ]] && unclassified_marquees_ref["$path"]="$marquee"
        [[ -n "$thumbnail" ]] && unclassified_thumbnails_ref["$path"]="$thumbnail"
        

    done < <(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "name" -o "|" -v "image" \
                -o "|" -v "video" -o "|" -v "marquee" -o "|" -v "thumbnail" -n ./gamelist.xml | \
                sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')
        # Se ñ tratar os &...; o xmlstarlet retorna como $amp; e ñ bate com o nome do arquivo
}

classify_xml_entries() {
    local -n unclassified_files_ref="$1"
    local -n xml_unclassified_entries_ref="$2"
    local -n xml_valid_games_ref="$3"
    local -n xml_ghost_entries_ref="$4"

    local path=""

    for path in "${!xml_unclassified_entries_ref[@]}"; do
        # Verifica a existência do arquivo e o remove da lista de ñ classificados se +
        if [[ -n "${unclassified_files_ref["$path"]:-}" ]]; then
            xml_valid_games_ref["$path"]="${xml_unclassified_entries_ref["$path"]}"
            unset 'unclassified_files_ref[$path]'
            # printf "Path: ${PINK}%s${ENDCOLOR} | Value: ${CYAN}%s${ENDCOLOR}\n\n" "$path" "${xml_unclassified_entries_ref[$path]}"
        
        else
            xml_ghost_entries_ref["$path"]="${xml_unclassified_entries_ref["$path"]}"
        
        fi
        unset 'xml_unclassified_entries_ref[$path]'
    done

}

classify_xml_asset() {
    local -n unclassified_files_ref="$1"
    local -n unclassified_assets_ref="$2"
    local -n valid_assets_ref="$3"
    local -n orphan_assets_ref="$4"
    local -n ghost_assets_ref="$5"
    local -n xml_valid_games_ref="$6"

    local path=""

     for path in "${!unclassified_assets_ref[@]}"; do
        local asset="${unclassified_assets_ref[$path]:-}"
            
        if [[ -n "${unclassified_files_ref["$asset"]:-}" ]]; then
        # se o arquivo existe, preciso verificar se é de um jogo válido ou um arquivo orfão
            if [[ -n "${xml_valid_games_ref["$path"]:-}" ]]; then
                valid_assets_ref["$path"]="$asset"

            else
                orphan_assets_ref["$path"]="$asset"

            fi
            # de um jeito ou de outro, o arquivo já foi classificado
            unset 'unclassified_files_ref[$asset]'

        else
            # se ñ é um arquivo existente, então é uma entrada/asset fantasma
            ghost_assets_ref["$path"]="$asset"

        fi
        # ao chegar aqui o asset já foi classificado e deve ser descartado dessa lista 
        unset 'unclassified_assets_ref[$path]'
     
     done

}

extract_possible_roms() {
    local -n unclassified_files_ref="$1"
    local -n possible_roms_ref="$2"

    local file=""
    local extension=""

    for file in "${!unclassified_files_ref[@]}"; do
        extension="${file##*.}"
        if [[ -n "${valid_extensions[$extension]:-}" ]]; then
            possible_roms_ref["$file"]=1
            unset 'unclassified_files_ref[$file]'
        
        fi

    done
}

group_files() {
    # Nesse ponto, podem existir arquivos como "Zombie Nation.nes" e "Zombie Nation.zip" ou "Resident Evil.cue" e "Resident Evil.bin",
    # então p/ classificar corretamente é preciso determinar oq é arquivo principal, oq é complementar, se é o msm jogo,
    # mas representado de outra forma... achei melhor agrupar os arquivos simalares primeiro p/ só depois classificar
    local -n files_to_group_ref="$1"
    local -n grouped_by_basename_ref="$2"

    local file=""
    local extension=""
    local base=""

    for file in "${!files_to_group_ref[@]}"; do
        # printf "Possível rom: ${PINK}%s${ENDCOLOR}\n" "$file"
        extension="${file##*.}"
        base="${file##*/}"
        base="${base%.*}"
        [[ "$base" == *.A1 ]]  && base="${base%.*}" # Alguns jogos (dreamcast) tem extensão dupla A1.bin e ñ dá pra só tirar td até o ponto na linha acima pq tem jogos com . no nome
        # poderia já classificar como arquivo complementar, mas pelo bem da consistência, não o farei!

        if [[ -z "${grouped_by_basename_ref["$base"]:-}" ]]; then
            grouped_by_basename_ref["$base"]="$file"

        else
            # printf "Já visto: ${YELLOW}%s${ENDCOLOR}\n" "$base"
            grouped_by_basename_ref["$base"]+="|$file"
        fi
    
    done

    # for base in "${!grouped_by_basename_ref[@]}"; do
    #     printf "Basename: ${YELLOW}%s${ENDCOLOR}\nValue: ${BLUE}%s${ENDCOLOR}\n\n" "$base"  "${grouped_by_basename_ref["$base"]}"  
    
    # done

}

gather_group_info() {
    local -n group_ref="$1"
    local -n num_of_itens_ref="$2"
    local -n extension_ref="$3"

    local file=""
    local ext=""

    num_of_itens_ref="${#group_ref[@]}"

    # printf "Qtd: ${GREEN}%s${ENDCOLOR}\n\n" "$num_of_itens_ref"


    for file in "${group_ref[@]}"; do
        # printf "Avaliando: ${BLUE}%s${ENDCOLOR}\n\n" "$file"
        ext="${file##*.}"

        extension_ref+=("$ext")        
    
    done

}

classify_possible_roms() {
    local -n grouped_possible_roms_ref="$1"
    local -n grouped_valid_games_ref="$2"
    local -n orphan_games_ref="$3"
    local -n auxiliary_files_ref="$4"
    local -n config_files_ref="$5"

    local basename=""
    local path=""
    local candidate_game=""
    local group=()
    local num_of_itens=0
    local extensions=()


    declare -A blacklist=(
        [konamigx]=1
        [kviper]=1
        [megatech]=1
        [nss]=1
        [playch10]=1
        [skns]=1
        [neogeo]=1
    )

    for basename in "${!grouped_possible_roms_ref[@]}"; do
        printf "Processando Grupo: ${CYAN}%s${ENDCOLOR}\n" "$basename"

        if [[ -n "${grouped_valid_games_ref["$basename"]:-}" ]]; then
        # se existe no grupo de jogos válidos, então tds os arquvios desse grupo são auxiliares ñ listados pelo xml
            printf "Arquivo ligado à ${RED}%s${ENDCOLOR}\n\n" "${grouped_valid_games_ref["$basename"]:-}"
            path="${grouped_valid_games_ref["$basename"]:-}"

            if [[ -z "${auxiliary_files_ref["$basename"]:-}" ]]; then
                auxiliary_files_ref["$path"]+="${grouped_possible_roms_ref["$basename"]}"

            else    
                auxiliary_files_ref["$path"]+="|${grouped_possible_roms_ref["$basename"]}"

            fi

        elif [[ -n "${blacklist[$basename]:-}" ]]; then
            path="${grouped_possible_roms_ref["$basename"]:-}"

            printf "${BLUE}%s${ENDCOLOR} é config\nNome: ${CYAN}%s${ENDCOLOR}\n\n" "$path" "$basename"
            config_files_ref["$path"]="$basename"

        else
            extensions=()
            
            IFS='|' read -ra group <<< "${grouped_possible_roms[$basename]}"

            gather_group_info group num_of_itens extensions

            if (( "$num_of_itens" == 1 )); then
                path="${grouped_possible_roms_ref["$basename"]:-}"

                printf "${GREEN}%s${ENDCOLOR} é orfão\nNome: ${YELLOW}%s${ENDCOLOR}\n\n" "$path" "$basename"
                orphan_games_ref["$path"]="$basename"

            else
               printf "${RED}%s${ENDCOLOR} tem de ser avaliado\n\n" "${grouped_possible_roms_ref["$basename"]}" 
            
            fi

           
        fi

    done

    # for path in "${!auxiliary_files_ref[@]}"; do
    #     printf "Path: ${PINK}%s${ENDCOLOR}\nAuxiliares: ${CYAN}%s${ENDCOLOR}\n\n" "$path" "${auxiliary_files_ref["$path"]}"

    
    # done


}

# find_unlisted_files() {
    #     local -n files="$1"
    #     local -n unlisted="$2"
    #     local -n matched="$3"
    #     local -n basenames="$4"

    #     local file=""
    #     local base=""

    #     for file in "${!files[@]}"; do
    #         if [[ -n "${matched["$file"]:-}" ]]; then
    #             base="${file##*/}"
    #             base="${base%.*}" 
    #             basenames["$base"]=1
            
    #         else
    #             unlisted["$file"]="$file"

    #         fi
        
    #     done

# }

# classify_unlisted_files() {
    #     local -n unlisted="$1"
    #     local -n basenames="$2"
    #     local -n auxiliary="$3"
    #     local -n orphans="$4"

    #     declare -A blacklist=(
    #         [konamigx]=1
    #         [kviper]=1
    #         [megatech]=1
    #         [nss]=1
    #         [playch10]=1
    #         [skns]=1
    #         [neogeo]=1
    #     ) # Existem formas mais robustas de separar jogos de arquivos de sistemas e afins, porém ñ é o foco no momento.
    #     local file=""
    #     local base=""

    #     for file in "${!unlisted[@]}"; do 
    #         base="${file##*/}"
    #         base="${base%.*}" 

    #         if [[ -n "${basenames["$base"]:-}" ]] || [[ "$base" == *.A1 ]] || [[ -n "${blacklist[$base]:-}" ]]; then
    #         # *.A1 sem "" p/ realizar comparação de padrões
    #         # Primeiro encontra os arquivos auxiliares dos jogos listados no xml
    #             auxiliary["$file"]="$file"

    #         else
    #             orphans["$file"]="$base"
    #         fi

    #     done
    #     exit

# }

build_game_library() {
    local -n matched="$1"
    local -n orphans="$2"
    local -n library="$3"

    local -A seen=()
    local all_games
    local game_name=""
    local checksum=""
    local short_checksum=""
    local path=""

    for path in "${!matched[@]}"; do
        library["$path"]="${matched[$path]}"
    done

    for path in "${!orphans[@]}"; do
    # Apesar dos arquivos serem únicos, muitos jogos possuem o msm nome (tô olhando pra
    # vcs do nes). Então é preciso marca-los de alguma forma p/ garantir q cada arquivo
    # esteja ligado corretamente ao nome do jogo. Ao acrescentar uma parte da hash md5
    # ao nome, se garante q o nome é "único" e q o usuário tem um marcador visual de
    # quais jogos possuem nomes iguais - ñ é a eficiência em pessoa,
    # mas resolve por enquanto
        game_name="${orphans[$path]}"

        if [[ -z "${seen[$game_name]:-}" ]]; then
            library["$path"]="$game_name"
            seen["$game_name"]=1

        else
            checksum=$(md5sum "$path")
            checksum=${checksum%% *}
            short_checksum=${checksum:0:4}


            library["$path"]="$game_name"
            library["$path"]+=" <<<$short_checksum>>>"
    
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
    mapfile -t -O "${#other_files[@]}" other_files < <(find . -type f -path "$name.*")
    
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

    printf "Criando xml temporário...\n" # Necessário por conta de process_other_files
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

find_games() {
    local -n dirs="$1"
    local -n games="$2"
    local target_game
    local lower_target
    local dir
    games=()

    read -r -p "Digite o nome do jogo: " target_game

    lower_target="${target_game,,}"


    for dir in "${dirs[@]}"; do

        local path=""
        local name=""
        while IFS='|' read -r path name; do

            path="${path#./}"
            local game_path="$dir$path"
                        
            if [[ -n "${games["$game_path"]:-}" ]]; then
                printf "${BLUE}DUPLICATA!!!!!!${ENDCOLOR}\n"
                printf "Name: ${CYAN}%s${ENDCOLOR}\nPath: ${PINK}%s${ENDCOLOR}\n\n" "$name" "$path"
                continue                   

            fi
            games["$game_path"]="$name"                        


        done < <(xmlstarlet sel -t -m "//game[contains(translate(name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '$lower_target')]" \
                    -v "path" -o "|" -v "name" -n ./"$dir"/gamelist.xml \
                    | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')

    done
       
        local file
        find . -type f -iname "*$lower_target*" -print0 | while IFS= read -r -d '' file; do
                file=${file#./}

                printf "\n${RED}Testando:${ENDCOLOR} %s\n" "$file"

                if [[ -n "${games["$file"]:-}" ]]; then
                    printf "Arquivo já encontrado no xml: ${GREEN}%s${ENDCOLOR}\n" "${games["$file"]}"
                fi
            done

 
}

count_by_dir() {
    local sum=0
    # for dir in "${dirs_with_games[@]}"; do
    # # Conta a qtd de jogos por pasta e soma o total - INACABADA
    #     game_files=()
    #     game_library=()
    #     xml_ghost_entries=()
    #     cd "$dir"
    #     printf "Analisando ${RED}%s${ENDCOLOR}\n" "$dir"
        
    #     get_all_files unclassified_files
                
    #     load_xml_entries xml_unclassified_entries

    #     classify_xml_entries xml_unclassified_entries unclassified_files xml_valid_games xml_ghost_entries

    #     find_unlisted_files unclassified_files unlisted_files xml_valid_games matched_basenames

    #     classify_unlisted_files unlisted_files matched_basenames auxiliary_files orphan_games

    #     build_game_library xml_valid_games orphan_games game_library

    #     printf "${CYAN}%s Jogos Encontrados${ENDCOLOR}\n\n" "${#game_library[@]}"
    #     (( sum += ${#game_library[@]} ))
    #     cd - &> /dev/null
    # done
    # printf "Total: ${GREEN}%s${ENDCOLOR}\n" "$sum"
    # exit
}

STATE="LOOK"
main_menu() {
    local dirs_list=(*/) # Lista de pastas no diretório atual - Glob expansion 
    local dirs_with_games=() 
    local dirs_without_games=()
    local dirs_to_look=() 
    local user_answer=""
    local -A unclassified_files=()
    local -A xml_unclassified_entries=()
    local -A xml_valid_games=()
    local -A xml_ghost_entries=()
    local -A unlisted_files=()
    local -A matched_basenames=()
    local -A auxiliary_files=()
    local -A orphan_games=() # Jogos que não estão presentes no gamelist.com
    local -A game_library=() # [chave/arquivo]=>[valor/nome do jogo]
    local selected_game_name=""
    local selected_game_path=""
    local using_find=0 # flag q controla certas ações ao "Procurar jogos"

    ### GLOŚSARIO ###
    # unclassified: existe em algum lugar (filesystem ou gamelist.xml), mas ainda ñ foi classificado
    # valid: existe no filesystem e já foi validado
    # orphan: existe no filesystem, porém ñ tem entrada no gamelist.xml ou a entrada ñ possuí o arquivo principal do jogo (no caso de assets)
    # ghost: existe apenas como entrada no gamelist.xml, sem ter um arquivo válido associado
    ### GLOŚSARIO ###

    printf "Avaliando Diretório:${GREEN} %s${ENDCOLOR}\n" "${PWD##*/}"
    printf "${YELLOW}%s Pastas Encontradas${ENDCOLOR}\n" "${#dirs_list[@]}"

    local -A system_paths=() valid_extensions=() valid_system_extensions=() systems_by_extension=()
    load_systems_info system_paths valid_extensions valid_system_extensions systems_by_extension



    while true; do
        case "$STATE" in
            "LOOK")
                echo "Procurando por pastas contendo ROMs..."
                classify_dirs_by_roms dirs_list dirs_with_games dirs_without_games

                printf "${YELLOW}%s Pastas contendo ROMs${ENDCOLOR}\n" "${#dirs_with_games[@]}" 
                printf "${CYAN}%s Pastas possuem apenas 'gamelist.xml'${ENDCOLOR}\n" "${#dirs_without_games[@]}" 

                ask_user "" user_answer "Ver pastas com ROMs" "Ver pastas sem ROMs" "Procurar jogo"
                case "$user_answer" in 
                    "Ver pastas com ROMs")
                        dirs_to_look=( "${dirs_with_games[@]}" )
                    ;;
                    "Ver pastas sem ROMs")
                        dirs_to_look=( "${dirs_without_games[@]}" )
                    ;;

                    "Procurar jogo")
                        using_find=1
                        dirs_to_look=( "${dirs_with_games[@]}" )
                        STATE="FIND_GAME"
                        continue
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
                unclassified_files=()
                xml_unclassified_entries=()
                xml_valid_games=()
                xml_ghost_entries=() # Entradas dentro do XML q ñ possuem um arquivo de jogo válido
                unlisted_files=()
                matched_basenames=()
                auxiliary_files=()
                orphan_games=()
                game_library=()

                local -A unclassified_images=() unclassified_videos=() unclassified_marquees=() unclassified_thumbnails=()
                local -A valid_images=() valid_videos=() valid_marquees=() valid_thumbnails=()
                local -A orphan_images=() orphan_videos=() orphan_marquees=() orphan_thumbnails=()
                local -A ghost_images=() ghost_videos=() ghost_marquees=() ghost_thumbnails=()

                get_all_files unclassified_files 
                
                load_xml_entries xml_unclassified_entries unclassified_images unclassified_videos unclassified_marquees unclassified_thumbnails

                classify_xml_entries unclassified_files xml_unclassified_entries xml_valid_games xml_ghost_entries

                local assets_names=( "images" "videos" "marquees" "thumbnails" )
                local name=""
                # certeza q tem forma de abstrair classify_xml_asset() p/ q lide com todos os assets de uma vez, mas por enquanto isso serve
                for name in "${assets_names[@]}"; do
                    local -n arr_ref="unclassified_${name}"
                    # printf "Tamanho de %s: %d\n" "${!arr_ref}" "${#arr_ref[@]}"
                    # se ñ há assets p/ serem classificados, ñ há necessidade de classificar oq não existe
                    (( ${#arr_ref[@]} > 0 )) && classify_xml_asset unclassified_files unclassified_${name} valid_${name} orphan_${name} ghost_${name} xml_valid_games
                done

##############################################################################################################################
                local -A possible_roms=() grouped_possible_roms=() grouped_valid_games=() config_files=()
                
                extract_possible_roms unclassified_files possible_roms
                group_files possible_roms grouped_possible_roms
                group_files xml_valid_games grouped_valid_games
                classify_possible_roms grouped_possible_roms grouped_valid_games orphan_games auxiliary_files config_files





                exit
##############################################################################################################################



                # find_unlisted_files unclassified_files unlisted_files xml_valid_games matched_basenames

                # classify_unlisted_files unlisted_files matched_basenames auxiliary_files orphan_games

                # build_game_library xml_valid_games orphan_games game_library

                printf "${YELLOW}%s Jogos Encontrados${ENDCOLOR}\n" "${#game_library[@]}"
                printf "${PINK}%s Jogos não estão listados no gamelist.xml${ENDCOLOR}\n" "${#orphan_games[@]}"
                printf "${CYAN}%s Entradas estão apenas no gamelist.xml${ENDCOLOR}\n" "${#xml_ghost_entries[@]}"
                # printf "${YELLOW}%s Arquivos auxiliares encontrados${ENDCOLOR}\n" "${#auxiliary_files[@]}"

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
                sorted_games=()                
                sort_games sorted_games "${game_library[@]}"

                ask_user "Selecione um jogo:" user_answer "${sorted_games[@]}" "Voltar"
                case "$user_answer" in
                    "Voltar")
                        if (( using_find )); then
                            using_find=0
                            STATE="LOOK"
                            continue
                            
                        fi
                        STATE="DIR_ACTION"
                    ;;

                    *)
                        selected_game_name="$user_answer"

                        for file in "${!game_library[@]}"; do # Vale lembrar q a chave/arquivo é igual ao path do gamelist.xmlz
                            if [[ "${game_library[$file]}" == "$selected_game_name" ]]; then
                                selected_game_path="$file"
                                break
                            fi
                        done

                        printf "Jogo selecionado: ${GREEN}%s${ENDCOLOR}\n" "$selected_game_name"
                        printf "Arquivo selecionado: ${CYAN}%s${ENDCOLOR}\n" "$selected_game_path"
                       
                        if (( using_find )); then
                            printf "Entrando na pasta${GREEN} %s${ENDCOLOR}\n" "${selected_game_path%%/*}"
                            cd -- "./${selected_game_path%%/*}" || exit 1
                            
                        fi
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
                            if (( using_find )); then
                                printf "Voltando p/ ${GREEN}%s${ENDCOLOR}\n" "$OLDPWD"
                                cd "$OLDPWD" || exit 1
                            
                            fi
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
            ;;

            "FIND_GAME")
                find_games dirs_to_look game_library

                if [[ "${#game_library[@]}" -lt 1 ]]; then
                    printf "${BLUE}Nenhum jogo encontrado.${ENDCOLOR}\n"
                else
                    printf "${YELLOW}%s jogos encontrados${ENDCOLOR}\n" "${#game_library[@]}"
                    STATE="GAMES_MENU"    

                fi    
            ;;

        esac
    done

}
main_menu "$@"