#!/bin/bash

echo "Avaliando Diretório"

dirs=(*/)
total_dirs=$(printf '%s\n' "${dirs[@]}" | wc -l)
printf '\e[32m%s Subpastas Encontradas\e[0m\n' "$total_dirs"

echo "Procurando por subpastas contendo ROMs..."

gamelist_dirs=()
for dir in "${dirs[@]}"; do  # Itera sobre cada diretório e checa se a saída de FIND ñ é uma string vazia -n
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
           if [[ ! $REPLY =~ ^[0-9]+$ ]] || [ "$REPLY" -lt 1 ] || [ "$REPLY" -gt "${#gamelist_dirs[@]}" ]; then
               echo "Opção inválida. Tente novamente."
               continue
           fi
           printf 'Entrando na subpasta: \e[36m%s\e[0m\n' "$dir"
           cd "$(pwd)/$dir"
           break
           ;;
   esac
done

#mapfile -t paths < <(awk -F'[<>]' '/<path>/{print $3}' gamelist.xml)
mapfile -t names < <(awk -F'[<>]' '/<name>/{print $3}' gamelist.xml)

select name in "${names[@]}" "Sair"; do
    case "$name" in
        "Sair")
            echo "Saindo..."
            exit 0
            ;;
        *)
            if [[ ! $REPLY =~ ^[0-9]+$ ]] || [ "$REPLY" -lt 1 ] || [ "$REPLY" -gt "${#names[@]}" ]; then
                echo "Opção inválida. Tente novamente."
                continue
            fi
            selected_name="$name"
            break
            ;;
    esac
done

printf 'Você selecionou: \e[36m%s\e[0m\n' "$selected_name"  

while true; do
read -p "O que deseja fazer com este jogo? Mover-> mv, Copiar-> cp, Deletar-> rm, Sair: " action
case "$action" in
        mv)
            read -p "Digite o caminho de destino para mover o jogo: " dest_path
            break
            ;;
        cp)
            read -p "Digite o caminho de destino para copiar o jogo: " dest_path
            break
            ;;
        rm)
            printf 'Deletando o jogo: \e[31m%s\e[0m\n' "$selected_name"
            break
            ;;
        Sair)
            echo "Saindo..."
            exit 0
            ;;
        *)
            echo "Escolha uma ação válida."
            continue
            ;;
    esac
done

#games=()
#for i in "${!paths[@]}"; do
#    games+=("${names[i]}|${paths[i]}")
#done            
#
#for game in "${games[@]}"; do
#    echo "$game"
#done