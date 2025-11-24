import psycopg2
import time
import random

DB_CONFIG = {
    'dbname': 'domino',
    'user': 'postgres',
    'password': '30427693', 
    'host': 'localhost',
    'port': '5432'
}

def conectar():
    return psycopg2.connect(**DB_CONFIG)

def log(msg):
    print(f"[SIMULAÇÃO] {msg}")

def criar_jogo_e_usuarios(cur):
    ids = []
    for i in range(4):
        email = f"bot_teste_{i+1}@simulacao.com"
        cur.execute("SELECT id_usuario FROM usuario WHERE email = %s", (email,))
        res = cur.fetchone()
        if res:
            ids.append(res[0])
        else:
            cur.execute("INSERT INTO usuario (nome, email) VALUES (%s, %s) RETURNING id_usuario", 
                        (f"Bot {i+1}", email))
            ids.append(cur.fetchone()[0])
    
    cur.execute("INSERT INTO jogo (status) VALUES ('ABERTO') RETURNING id_jogo")
    id_jogo = cur.fetchone()[0]
    
    equipes = ['A', 'B', 'A', 'B']
    for i, uid in enumerate(ids):
        cur.execute("INSERT INTO jogo_jogador (id_jogo, id_usuario, posicao_mesa, equipe) VALUES (%s, %s, %s, %s)",
                    (id_jogo, uid, i+1, equipes[i]))
        
    return id_jogo, ids

def criar_nova_partida(cur, id_jogo, ids_usuarios):
    cur.execute("INSERT INTO partida (id_jogo) VALUES (%s) RETURNING id_partida", (id_jogo,))
    id_partida = cur.fetchone()[0]
    
    cur.execute("SELECT id_peca FROM peca")
    pecas = [r[0] for r in cur.fetchall()]
    random.shuffle(pecas)
    
    idx = 0
    for uid in ids_usuarios:
        mao = pecas[idx:idx+7]
        idx += 7
        for p in mao:
            cur.execute("INSERT INTO mao_jogador (id_partida, id_peca, id_usuario, localizacao) VALUES (%s, %s, %s, 'MAO')",
                        (id_partida, p, uid))
    return id_partida

def jogar_uma_partida(cur, id_jogo, id_partida, ids_jogadores):
    cur.execute("""
        SELECT mj.id_usuario, p.id_peca 
        FROM mao_jogador mj JOIN peca p ON mj.id_peca = p.id_peca
        WHERE mj.id_partida = %s AND p.lado_a = 6 AND p.lado_b = 6
    """, (id_partida,))
    res_inicio = cur.fetchone()
    
    if res_inicio:
        dono_66, id_peca_66 = res_inicio
    else:
        dono_66 = ids_jogadores[0] 
        id_peca_66 = None

    idx_inicio = ids_jogadores.index(dono_66)
    fila = ids_jogadores[idx_inicio:] + ids_jogadores[:idx_inicio]
    
    partida_rolando = True
    turno = 0
    passes_consecutivos = 0
    
    while partida_rolando:
        jogador_atual = fila[turno % 4]
        
        cur.execute("SELECT ponta_mesa_1, ponta_mesa_2 FROM partida WHERE id_partida = %s", (id_partida,))
        res_mesa = cur.fetchone()
        p1, p2 = res_mesa if res_mesa else (None, None)
        
        cur.execute("""
            SELECT p.id_peca, p.lado_a, p.lado_b 
            FROM mao_jogador mj JOIN peca p ON mj.id_peca = p.id_peca
            WHERE mj.id_partida = %s AND mj.id_usuario = %s AND mj.localizacao = 'MAO'
        """, (id_partida, jogador_atual))
        mao = cur.fetchall()
        
        jogou = False
        
        if turno == 0 and id_peca_66 and jogador_atual == dono_66:
             try:
                cur.execute("CALL sp_realizar_jogada(%s, %s, %s)", (jogador_atual, id_partida, id_peca_66))
                jogou = True
             except: pass
        else:
            for peca in mao:
                pid, la, lb = peca
                if (p1 is None) or (la == p1 or la == p2 or lb == p1 or lb == p2):
                    try:
                        cur.execute("CALL sp_realizar_jogada(%s, %s, %s)", (jogador_atual, id_partida, pid))
                        jogou = True
                        break
                    except: pass
        
        if jogou:
            passes_consecutivos = 0
        else:
            passes_consecutivos += 1
        
        if passes_consecutivos >= 4:
            log("!!! 4 passes seguidos. Forçando TRANCAMENTO via banco...")
            cur.execute("UPDATE partida SET status = 'TRANCADA', data_fim = NOW() WHERE id_partida = %s", (id_partida,))
            partida_rolando = False
            break
        cur.execute("SELECT status, vencedor_equipe FROM partida WHERE id_partida = %s", (id_partida,))
        st_partida, v_partida = cur.fetchone()
        
        if st_partida == 'EM_ANDAMENTO':
             cur.execute("SELECT fn_verificar_trancamento(%s)", (id_partida,))
             if cur.fetchone()[0]:
                 st_partida = 'TRANCADA'

        if st_partida in ('FINALIZADA', 'TRANCADA'):
            log(f"   -> Fim da Rodada. Resultado: {st_partida}. Vencedor Rodada: {v_partida}")
            partida_rolando = False
        
        turno += 1

def executar_campeonato():
    conn = conectar()
    conn.autocommit = True
    cur = conn.cursor()
    
    try:
        log("=== INICIANDO CAMPEONATO ATÉ 50 PONTOS ===")
        
        id_jogo, ids_jogadores = criar_jogo_e_usuarios(cur)
        log(f"JOGO {id_jogo} CRIADO! ID da Sessão: {id_jogo}")
        
        jogo_ativo = True
        num_partida = 1
        
        while jogo_ativo:
            log(f"\n--- Iniciando Partida {num_partida} ---")
            
            id_partida = criar_nova_partida(cur, id_jogo, ids_jogadores)
            
            jogar_uma_partida(cur, id_jogo, id_partida, ids_jogadores)
            
            cur.execute("SELECT equipe, pontuacao_acumulada FROM jogo_jogador WHERE id_jogo = %s GROUP BY equipe, pontuacao_acumulada", (id_jogo,))
            placar = cur.fetchall()
            log(f"PLACAR GERAL: {placar}")
            
            cur.execute("SELECT status, vencedor_equipe FROM jogo WHERE id_jogo = %s", (id_jogo,))
            st_jogo, v_jogo = cur.fetchone()
            
            if st_jogo == 'FINALIZADO':
                log("="*40)
                log(f"CAMPEONATO ENCERRADO! VENCEDOR DO JOGO: EQUIPE {v_jogo}")
                log("="*40)
                jogo_ativo = False
            else:
                num_partida += 1
                time.sleep(0.5) 
            
    except Exception as e:
        log(f"ERRO CRÍTICO: {e}")
    finally:
        conn.close()

if __name__ == "__main__":
    executar_campeonato()