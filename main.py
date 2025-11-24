import psycopg2
import random
import os
import sys

DB_CONFIG = {
    'dbname': 'domino',
    'user': 'postgres',
    'password': '30427693',
    'host': 'localhost',
    'port': '5432'
}

def conectar():
    return psycopg2.connect(**DB_CONFIG)

def limpar_tela():
    os.system('cls' if os.name == 'nt' else 'clear')

def cadastrar_usuarios_dinamico(cursor, qtd_jogadores):
    """Cria ou recupera N usuários para a partida"""
    ids = []
    print(f"\n--- Cadastrando {qtd_jogadores} Jogadores ---")
    for i in range(qtd_jogadores):
        nome = f"Jogador {i+1}"
        email = f"jogador{i+1}@domino.com"

        cursor.execute("SELECT id_usuario FROM usuario WHERE email = %s", (email,))
        res = cursor.fetchone()

        if res:
            ids.append(res[0])
        else:
            cursor.execute("INSERT INTO usuario (nome, email) VALUES (%s, %s) RETURNING id_usuario", (nome, email))
            ids.append(cursor.fetchone()[0])

    return ids

def iniciar_jogo_e_partida(cursor, ids_usuarios):
    qtd = len(ids_usuarios)

    cursor.execute("INSERT INTO jogo (status) VALUES ('ABERTO') RETURNING id_jogo")
    id_jogo = cursor.fetchone()[0]
    print(f"Jogo {id_jogo} iniciado!")

    if qtd == 4:
        equipes_lista = ['A', 'B', 'A', 'B']
    else:
        equipes_lista = ['A', 'B', 'C', 'D']

    for i, id_user in enumerate(ids_usuarios):
        equipe = equipes_lista[i]
        posicao = i + 1
        cursor.execute("""
            INSERT INTO jogo_jogador (id_jogo, id_usuario, posicao_mesa, equipe) 
            VALUES (%s, %s, %s, %s)
        """, (id_jogo, id_user, posicao, equipe))

    cursor.execute("INSERT INTO partida (id_jogo) VALUES (%s) RETURNING id_partida", (id_jogo,))
    id_partida = cursor.fetchone()[0]

    cursor.execute("SELECT id_peca FROM peca")
    todas_pecas = [r[0] for r in cursor.fetchall()]
    random.shuffle(todas_pecas)

    indice_deck = 0
    for id_user in ids_usuarios:
        mao = todas_pecas[indice_deck : indice_deck+7]
        indice_deck += 7
        for p in mao:
            cursor.execute("INSERT INTO mao_jogador (id_partida, id_peca, id_usuario, localizacao) VALUES (%s, %s, %s, 'MAO')", 
                           (id_partida, p, id_user))

    monte = todas_pecas[indice_deck:]
    for p in monte:
        cursor.execute("INSERT INTO mao_jogador (id_partida, id_peca, localizacao) VALUES (%s, %s, 'MONTE')", 
                       (id_partida, p))

    return id_partida

def encontrar_primeiro_jogador(cursor, id_partida, ids_usuarios):
    """
    Regra: Começa quem tem a peça 6-6.
    Se ninguém tiver (estiver no monte), procura a 5-5, 4-4...
    """
    doubles = [(6,6), (5,5), (4,4), (3,3), (2,2), (1,1), (0,0)]

    for d in doubles:
        cursor.execute("SELECT id_peca FROM peca WHERE lado_a = %s AND lado_b = %s", (d[0], d[1]))
        id_peca = cursor.fetchone()[0]

        cursor.execute("""
            SELECT id_usuario FROM mao_jogador 
            WHERE id_partida = %s AND id_peca = %s AND localizacao = 'MAO'
        """, (id_partida, id_peca))
        res = cursor.fetchone()

        if res:
            dono = res[0]
            print(f"\n>> O Jogo começa com o dono da peça {d[0]}-{d[1]} (ID Usuário: {dono})")
            return dono, id_peca

    print("Nenhum double nas mãos! (Caso raríssimo). Começa o Jogador 1.")
    return ids_usuarios[0], None

def mostrar_mesa(cursor, id_partida):
    cursor.execute("SELECT ponta_mesa_1, ponta_mesa_2 FROM partida WHERE id_partida = %s", (id_partida,))
    res = cursor.fetchone()
    if res:
        p1, p2 = res
        print("\n" + "="*40)
        print(f"   MESA: [ {p1 if p1 is not None else '?'} | {p2 if p2 is not None else '?'} ]")
        print("="*40)
        return p1, p2
    return None, None

def mostrar_mao(cursor, id_partida, id_usuario):
    cursor.execute("""
        SELECT p.id_peca, p.lado_a, p.lado_b 
        FROM mao_jogador mj
        JOIN peca p ON mj.id_peca = p.id_peca
        WHERE mj.id_partida = %s AND mj.id_usuario = %s AND mj.localizacao = 'MAO'
        ORDER BY p.lado_a, p.lado_b
    """, (id_partida, id_usuario))
    pecas = cursor.fetchall()
    print(f"\n> Sua mão (ID Usuário: {id_usuario}):")
    lista_formatada = []
    ids_validos = []
    for p in pecas:
        lista_formatada.append(f"[{p[1]}-{p[2]}] (ID:{p[0]})")
        ids_validos.append(p[0])

    print("  " + "  ".join(lista_formatada))
    return ids_validos

def loop_jogo():
    conn = None
    try:
        conn = conectar()
        conn.autocommit = True 
        cur = conn.cursor()

        limpar_tela()
        print("=== CAPIVARA GAME: DOMINÓ ===")

        while True:
            try:
                qtd_jogadores = int(input("Quantos jogadores (2, 3 ou 4)? "))
                if qtd_jogadores in [2, 3, 4]:
                    break
                print("Por favor, escolha 2, 3 ou 4.")
            except ValueError:
                print("Digite um número.")

        ids_usuarios = cadastrar_usuarios_dinamico(cur, qtd_jogadores)
        id_partida = iniciar_jogo_e_partida(cur, ids_usuarios)

        id_inicial, id_peca_inicial = encontrar_primeiro_jogador(cur, id_partida, ids_usuarios)

        idx_inicio = ids_usuarios.index(id_inicial)
        ordem_turnos = ids_usuarios[idx_inicio:] + ids_usuarios[:idx_inicio]

        turno_count = 0
        jogo_ativo = True
        primeira_jogada = True

        while jogo_ativo:
            jogador_atual = ordem_turnos[turno_count % qtd_jogadores]

            cur.execute("SELECT nome FROM usuario WHERE id_usuario = %s", (jogador_atual,))
            nome_jogador = cur.fetchone()[0]

            ponta1, ponta2 = mostrar_mesa(cur, id_partida)

            print(f"\n>>> VEZ DE: {nome_jogador} (ID: {jogador_atual})")

            if primeira_jogada and id_peca_inicial:
                print(f"!!! ATENÇÃO: Você tem a saída! Deve jogar a peça ID {id_peca_inicial}.")

            mostrar_mao(cur, id_partida, jogador_atual)

            print("\n[1] JOGAR  |  [2] COMPRAR  |  [3] PASSAR  |  [0] SAIR")
            opcao = input("Opção: ")

            if opcao == '1':
                id_peca_str = input("ID da peça: ")
                if id_peca_str.isdigit():
                    id_peca = int(id_peca_str)

                    if primeira_jogada and id_peca_inicial and id_peca != id_peca_inicial:
                        print(f"REGRA: Você deve começar com a peça obrigatória (ID {id_peca_inicial})!")
                        continue

                    try:
                        cur.execute("CALL sp_realizar_jogada(%s, %s, %s)", (jogador_atual, id_partida, id_peca))
                        print("\n>> Jogada realizada!")
                        turno_count += 1
                        primeira_jogada = False
                    except psycopg2.DatabaseError as e:
                        print(f"\nXX ERRO DO BANCO: {e.pgerror}")
                else:
                    print("ID inválido.")

            elif opcao == '2':
                if qtd_jogadores == 4:
                    print("Jogo de 4 jogadores não tem compra! Se não tiver peça, PASSE.")
                else:
                    try:
                        cur.execute("CALL sp_comprar_peca(%s, %s)", (jogador_atual, id_partida))
                        print("\n>> Peça comprada! Verifique sua mão.")
                    except psycopg2.DatabaseError as e:
                        print(f"Aviso: {e}")

            elif opcao == '3':
                print("\n>> Passou a vez.")
                turno_count += 1

            elif opcao == '0':
                print("Saindo...")
                break

            cur.execute("SELECT status, vencedor_equipe FROM partida WHERE id_partida = %s", (id_partida,))
            dados_partida = cur.fetchone()

            if dados_partida and dados_partida[0] != 'EM_ANDAMENTO':
                status = dados_partida[0]
                vencedor = dados_partida[1]
                print(f"\n==========================================")
                print(f"FIM DE PARTIDA! Status: {status}")
                if vencedor:
                    print(f"Equipe Vencedora: {vencedor}")
                print(f"==========================================")
                jogo_ativo = False

    except Exception as e:
        print(f"Erro: {e}")
    finally:
        if conn: conn.close()

if __name__ == "__main__":
    loop_jogo()