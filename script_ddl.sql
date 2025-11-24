-- ==============================================================================
-- SCRIPT DE CRIAÇÃO DO BANCO DE DADOS
-- ==============================================================================

-- Limpeza inicial (caso precise recriar do zero)
DROP TABLE IF EXISTS jogada CASCADE;
DROP TABLE IF EXISTS mao_jogador CASCADE;
DROP TABLE IF EXISTS partida CASCADE;
DROP TABLE IF EXISTS jogo_jogador CASCADE;
DROP TABLE IF EXISTS jogo CASCADE;
DROP TABLE IF EXISTS peca CASCADE;
DROP TABLE IF EXISTS usuario CASCADE;

-- ------------------------------------------------------------------------------
-- 1. ESTRUTURA DAS TABELAS (DDL)
-- ------------------------------------------------------------------------------

-- 1. Tabela de Usuários
CREATE TABLE usuario (
    id_usuario SERIAL PRIMARY KEY,
    nome VARCHAR(128) NOT NULL,  
    email VARCHAR(128) UNIQUE NOT NULL, 
    data_cadastro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. Tabela das Peças de Dominó (Estática)
CREATE TABLE peca (
    id_peca SERIAL PRIMARY KEY,
    lado_a INT NOT NULL CHECK (lado_a >= 0 AND lado_a <= 6),
    lado_b INT NOT NULL CHECK (lado_b >= 0 AND lado_b <= 6),
    valor_pontos INT GENERATED ALWAYS AS (lado_a + lado_b) STORED,
    UNIQUE (lado_a, lado_b)
);

-- 3. Tabela de Jogos
CREATE TABLE jogo (
    id_jogo SERIAL PRIMARY KEY,
    data_inicio TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    data_fim TIMESTAMP,
    status VARCHAR(16) DEFAULT 'ABERTO' CHECK (status IN ('ABERTO', 'FINALIZADO')),
    vencedor_equipe CHAR(1) 
);

-- 4. Tabela de Associação Jogo-Jogador
CREATE TABLE jogo_jogador (
    id_jogo INT REFERENCES jogo(id_jogo),
    id_usuario INT REFERENCES usuario(id_usuario),
    posicao_mesa INT CHECK (posicao_mesa BETWEEN 1 AND 4),
    equipe CHAR(1) CHECK (equipe IN ('A', 'B', 'C', 'D')), -- Aceita até 4 equipes (para jogo individual)
    pontuacao_acumulada INT DEFAULT 0,
    PRIMARY KEY (id_jogo, id_usuario)
);

-- 5. Tabela de Partidas
CREATE TABLE partida (
    id_partida SERIAL PRIMARY KEY,
    id_jogo INT REFERENCES jogo(id_jogo),
    data_inicio TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    data_fim TIMESTAMP,
    status VARCHAR(16) DEFAULT 'EM_ANDAMENTO' CHECK (status IN ('EM_ANDAMENTO', 'FINALIZADA', 'TRANCADA')),
    ponta_mesa_1 INT DEFAULT NULL, 
    ponta_mesa_2 INT DEFAULT NULL,
    vencedor_equipe CHAR(1)
);

-- 6. Tabela Mão do Jogador
CREATE TABLE mao_jogador (
    id_partida INT REFERENCES partida(id_partida),
    id_peca INT REFERENCES peca(id_peca),
    id_usuario INT REFERENCES usuario(id_usuario),
    localizacao VARCHAR(8) CHECK (localizacao IN ('MAO', 'MESA', 'MONTE')),
    PRIMARY KEY (id_partida, id_peca)
);

-- 7. Tabela de Jogadas (Histórico)
CREATE TABLE jogada (
    id_jogada SERIAL PRIMARY KEY,
    id_partida INT REFERENCES partida(id_partida),
    id_usuario INT REFERENCES usuario(id_usuario),
    id_peca INT REFERENCES peca(id_peca),
    numero_jogada INT NOT NULL,
    lado_conectado INT, 
    tipo_movimento VARCHAR(8) DEFAULT 'JOGAR' CHECK (tipo_movimento IN ('JOGAR', 'PASSAR', 'COMPRAR')),
    data_hora TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ------------------------------------------------------------------------------
-- 2. CARGA DE DADOS INICIAL (DML)
-- ------------------------------------------------------------------------------

INSERT INTO peca (lado_a, lado_b) VALUES
(0,0), (0,1), (0,2), (0,3), (0,4), (0,5), (0,6),
(1,1), (1,2), (1,3), (1,4), (1,5), (1,6),
(2,2), (2,3), (2,4), (2,5), (2,6),
(3,3), (3,4), (3,5), (3,6),
(4,4), (4,5), (4,6),
(5,5), (5,6),
(6,6);

-- ------------------------------------------------------------------------------
-- 3. LÓGICA DE NEGÓCIO (FUNCTIONS & PROCEDURES)
-- ------------------------------------------------------------------------------

-- Função: Validar se a peça encaixa na mesa
CREATE OR REPLACE FUNCTION fn_validar_jogada(p_id_partida INT, p_lado_a INT, p_lado_b INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_ponta1 INT;
    v_ponta2 INT;
BEGIN
    SELECT ponta_mesa_1, ponta_mesa_2 INTO v_ponta1, v_ponta2
    FROM partida
    WHERE id_partida = p_id_partida;

    IF v_ponta1 IS NULL AND v_ponta2 IS NULL THEN
        RETURN TRUE;
    END IF;

    IF (p_lado_a = v_ponta1 OR p_lado_a = v_ponta2 OR 
        p_lado_b = v_ponta1 OR p_lado_b = v_ponta2) THEN
        RETURN TRUE;
    ELSE
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Função: Verificar se o jogo trancou
CREATE OR REPLACE FUNCTION fn_verificar_trancamento(p_id_partida INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_ponta1 INT;
    v_ponta2 INT;
    v_tem_jogada_possivel BOOLEAN;
    v_monte_tem_peca BOOLEAN;
BEGIN
    SELECT ponta_mesa_1, ponta_mesa_2 INTO v_ponta1, v_ponta2
    FROM partida WHERE id_partida = p_id_partida;

    IF v_ponta1 IS NULL THEN RETURN FALSE; END IF;

    SELECT EXISTS(SELECT 1 FROM mao_jogador WHERE id_partida = p_id_partida AND localizacao = 'MONTE')
    INTO v_monte_tem_peca;

    IF v_monte_tem_peca THEN
        RETURN FALSE; 
    END IF;

    SELECT EXISTS (
        SELECT 1 
        FROM mao_jogador mj
        JOIN peca p ON mj.id_peca = p.id_peca
        WHERE mj.id_partida = p_id_partida 
          AND mj.localizacao = 'MAO'
          AND (p.lado_a IN (v_ponta1, v_ponta2) OR p.lado_b IN (v_ponta1, v_ponta2))
    ) INTO v_tem_jogada_possivel;

    IF NOT v_tem_jogada_possivel THEN
        UPDATE partida SET status = 'TRANCADA', data_fim = NOW() WHERE id_partida = p_id_partida;
        RETURN TRUE;
    END IF;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Procedure: Comprar peça do monte
CREATE OR REPLACE PROCEDURE sp_comprar_peca(
    p_id_usuario INT,
    p_id_partida INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_peca_comprada INT;
BEGIN
    SELECT id_peca INTO v_id_peca_comprada
    FROM mao_jogador
    WHERE id_partida = p_id_partida 
      AND localizacao = 'MONTE'
    ORDER BY RANDOM()
    LIMIT 1;

    IF v_id_peca_comprada IS NULL THEN
        RAISE NOTICE 'O monte está vazio! Não há peças para comprar.';
        RETURN;
    END IF;

    UPDATE mao_jogador
    SET id_usuario = p_id_usuario,
        localizacao = 'MAO'
    WHERE id_partida = p_id_partida 
      AND id_peca = v_id_peca_comprada;

    INSERT INTO jogada (id_partida, id_usuario, id_peca, numero_jogada, tipo_movimento)
    VALUES (
        p_id_partida, 
        p_id_usuario, 
        v_id_peca_comprada, 
        (SELECT count(*)+1 FROM jogada WHERE id_partida = p_id_partida), 
        'COMPRAR'
    );
END;
$$;

-- Procedure Principal: Realizar Jogada
CREATE OR REPLACE PROCEDURE sp_realizar_jogada(
    p_id_usuario INT, 
    p_id_partida INT, 
    p_id_peca INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_lado_a INT;
    v_lado_b INT;
    v_ponta1 INT;
    v_ponta2 INT;
    v_lado_conectado INT;
    v_qtd_jogadas INT;
BEGIN
    -- 1. Obter dados da peça
    SELECT lado_a, lado_b INTO v_lado_a, v_lado_b FROM peca WHERE id_peca = p_id_peca;

    -- 2. Validar posse
    PERFORM 1 FROM mao_jogador 
    WHERE id_partida = p_id_partida AND id_usuario = p_id_usuario AND id_peca = p_id_peca AND localizacao = 'MAO';
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esta peça não pertence ao jogador ou já foi jogada.';
    END IF;

    -- 3. Obter mesa e validar encaixe
    SELECT ponta_mesa_1, ponta_mesa_2 INTO v_ponta1, v_ponta2 FROM partida WHERE id_partida = p_id_partida;

    IF v_ponta1 IS NULL THEN 
        UPDATE partida SET ponta_mesa_1 = v_lado_a, ponta_mesa_2 = v_lado_b WHERE id_partida = p_id_partida;
        v_lado_conectado := NULL; 
    ELSE
        IF v_lado_a = v_ponta1 THEN
            UPDATE partida SET ponta_mesa_1 = v_lado_b WHERE id_partida = p_id_partida;
            v_lado_conectado := v_ponta1;
        ELSIF v_lado_b = v_ponta1 THEN
            UPDATE partida SET ponta_mesa_1 = v_lado_a WHERE id_partida = p_id_partida;
            v_lado_conectado := v_ponta1;
        ELSIF v_lado_a = v_ponta2 THEN
            UPDATE partida SET ponta_mesa_2 = v_lado_b WHERE id_partida = p_id_partida;
            v_lado_conectado := v_ponta2;
        ELSIF v_lado_b = v_ponta2 THEN
            UPDATE partida SET ponta_mesa_2 = v_lado_a WHERE id_partida = p_id_partida;
            v_lado_conectado := v_ponta2;
        ELSE
            RAISE EXCEPTION 'Jogada inválida! A peça não encaixa na mesa.';
        END IF;
    END IF;

    -- 4. Atualizar localização e histórico
    UPDATE mao_jogador SET localizacao = 'MESA' 
    WHERE id_partida = p_id_partida AND id_peca = p_id_peca;

    SELECT count(*) + 1 INTO v_qtd_jogadas FROM jogada WHERE id_partida = p_id_partida;
    
    INSERT INTO jogada (id_partida, id_usuario, id_peca, numero_jogada, lado_conectado, tipo_movimento)
    VALUES (p_id_partida, p_id_usuario, p_id_peca, v_qtd_jogadas, v_lado_conectado, 'JOGAR');

    -- 5. Verificar se bateu
    IF NOT EXISTS (SELECT 1 FROM mao_jogador WHERE id_partida = p_id_partida AND id_usuario = p_id_usuario AND localizacao = 'MAO') THEN
        UPDATE partida SET status = 'FINALIZADA', data_fim = NOW(), vencedor_equipe = (SELECT equipe FROM jogo_jogador WHERE id_usuario = p_id_usuario AND id_jogo = (SELECT id_jogo FROM partida WHERE id_partida = p_id_partida))
        WHERE id_partida = p_id_partida;
    END IF;

    COMMIT;
END;
$$;

-- ------------------------------------------------------------------------------
-- 4. GATILHOS (TRIGGERS) - Versão corrigida com LIMIT 1
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_calcular_pontos_fim() RETURNS TRIGGER AS $$
DECLARE
    v_pontos_perdedores INT;
    v_equipe_vencedora CHAR(1);
    v_id_jogo INT;
BEGIN
    -- Só executa se a partida acabou de ser finalizada
    IF NEW.status = 'FINALIZADA' AND OLD.status <> 'FINALIZADA' THEN
        
        v_equipe_vencedora := NEW.vencedor_equipe;
        v_id_jogo := NEW.id_jogo;

        -- 1. Calcula pontos dos perdedores
        SELECT COALESCE(SUM(p.valor_pontos), 0) INTO v_pontos_perdedores
        FROM mao_jogador mj
        JOIN peca p ON mj.id_peca = p.id_peca
        WHERE mj.id_partida = NEW.id_partida AND mj.localizacao = 'MAO';

        -- 2. Atualiza a pontuação de TODOS os membros da equipe vencedora
        UPDATE jogo_jogador
        SET pontuacao_acumulada = pontuacao_acumulada + v_pontos_perdedores
        WHERE id_jogo = v_id_jogo AND equipe = v_equipe_vencedora;
        
        -- 3. Verificação de Segurança para Fechar o Jogo
        -- Verifica diretamente na tabela se ALGUÉM desse jogo atingiu 50 pontos
        IF EXISTS (
            SELECT 1 
            FROM jogo_jogador 
            WHERE id_jogo = v_id_jogo AND pontuacao_acumulada >= 50
        ) THEN
            UPDATE jogo 
            SET status = 'FINALIZADA', 
                data_fim = NOW(), 
                vencedor_equipe = v_equipe_vencedora 
            WHERE id_jogo = v_id_jogo;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_calcular_pontos
AFTER UPDATE ON partida
FOR EACH ROW
EXECUTE FUNCTION fn_calcular_pontos_fim();

-- ------------------------------------------------------------------------------
-- 5. VISÕES (VIEWS)
-- ------------------------------------------------------------------------------

-- Visão: Detalhes das Partidas
CREATE OR REPLACE VIEW vw_detalhes_partidas AS
SELECT 
    p.id_partida,
    j.id_jogo,
    p.data_inicio,
    p.status,
    p.vencedor_equipe,
    p.ponta_mesa_1,
    p.ponta_mesa_2
FROM partida p
JOIN jogo j ON p.id_jogo = j.id_jogo;

-- Visão: Ranking Completo (Jogos Vencidos + Pontos em Jogo Atual)
CREATE OR REPLACE VIEW vw_ranking_usuarios AS
SELECT 
    u.nome,
    COUNT(j.id_jogo) FILTER (WHERE j.status = 'FINALIZADA' AND j.vencedor_equipe = jj.equipe) AS jogos_vencidos,
    SUM(jj.pontuacao_acumulada) FILTER (WHERE j.status = 'ABERTO') as pontos_em_jogo_atual
FROM usuario u
JOIN jogo_jogador jj ON u.id_usuario = jj.id_usuario
JOIN jogo j ON jj.id_jogo = j.id_jogo
GROUP BY u.nome
ORDER BY jogos_vencidos DESC, pontos_em_jogo_atual DESC;

TRUNCATE TABLE jogada, mao_jogador, partida, jogo_jogador, jogo, usuario CASCADE;

CREATE OR REPLACE FUNCTION fn_calcular_pontos_fim() RETURNS TRIGGER AS $$
DECLARE
    v_pontos_total INT;
    v_pontos_equipe_A INT;
    v_pontos_equipe_B INT;
    v_equipe_vencedora CHAR(1);
    v_id_jogo INT;
BEGIN
    -- 'partida' usa FINALIZADA / TRANCADA (Feminino)
    IF (NEW.status IN ('FINALIZADA', 'TRANCADA')) AND (OLD.status NOT IN ('FINALIZADA', 'TRANCADA')) THEN
        
        v_id_jogo := NEW.id_jogo;
        v_equipe_vencedora := NULL; 

        -- CASO 1: ALGUÉM BATEU
        IF NEW.status = 'FINALIZADA' THEN
            v_equipe_vencedora := NEW.vencedor_equipe;
            
            SELECT COALESCE(SUM(p.valor_pontos), 0) INTO v_pontos_total
            FROM mao_jogador mj
            JOIN peca p ON mj.id_peca = p.id_peca
            WHERE mj.id_partida = NEW.id_partida AND mj.localizacao = 'MAO';

        -- CASO 2: JOGO TRANCOU
        ELSIF NEW.status = 'TRANCADA' THEN
            -- Soma A
            SELECT COALESCE(SUM(p.valor_pontos), 0) INTO v_pontos_equipe_A
            FROM mao_jogador mj
            JOIN peca p ON mj.id_peca = p.id_peca
            JOIN jogo_jogador jj ON mj.id_usuario = jj.id_usuario
            WHERE mj.id_partida = NEW.id_partida AND mj.localizacao = 'MAO' AND jj.equipe = 'A';

            -- Soma B
            SELECT COALESCE(SUM(p.valor_pontos), 0) INTO v_pontos_equipe_B
            FROM mao_jogador mj
            JOIN peca p ON mj.id_peca = p.id_peca
            JOIN jogo_jogador jj ON mj.id_usuario = jj.id_usuario
            WHERE mj.id_partida = NEW.id_partida AND mj.localizacao = 'MAO' AND jj.equipe = 'B';

            -- Decide Vencedor (Menor pontuação ganha)
            IF v_pontos_equipe_A < v_pontos_equipe_B THEN
                v_equipe_vencedora := 'A';
                v_pontos_total := v_pontos_equipe_A + v_pontos_equipe_B;
            ELSIF v_pontos_equipe_B < v_pontos_equipe_A THEN
                v_equipe_vencedora := 'B';
                v_pontos_total := v_pontos_equipe_A + v_pontos_equipe_B;
            ELSE
                v_pontos_total := 0; 
            END IF;
            
            IF v_equipe_vencedora IS NOT NULL THEN
                UPDATE partida SET vencedor_equipe = v_equipe_vencedora WHERE id_partida = NEW.id_partida;
            END IF;
        END IF;

        -- ATUALIZA O PLACAR GERAL
        IF v_equipe_vencedora IS NOT NULL AND v_pontos_total > 0 THEN
            UPDATE jogo_jogador
            SET pontuacao_acumulada = pontuacao_acumulada + v_pontos_total
            WHERE id_jogo = v_id_jogo AND equipe = v_equipe_vencedora;
        END IF;

        -- VERIFICA SE O JOGO ACABOU (50 PONTOS)
        IF EXISTS (SELECT 1 FROM jogo_jogador WHERE id_jogo = v_id_jogo AND pontuacao_acumulada >= 50) THEN
            
            UPDATE jogo 
            SET status = 'FINALIZADO', 
                data_fim = NOW(), 
                vencedor_equipe = (SELECT equipe FROM jogo_jogador WHERE id_jogo = v_id_jogo ORDER BY pontuacao_acumulada DESC LIMIT 1)
            WHERE id_jogo = v_id_jogo;
            
        END IF;

    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;