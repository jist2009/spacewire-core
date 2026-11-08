library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spw_link_fsm is
    generic (
        CLK_FREQ_HZ : positive := 50_000_000 -- Horloge à 50 MHz
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Signaux de contrôle utilisateur
        link_start      : in  std_logic;
        link_disable    : in  std_logic;
        auto_start      : in  std_logic;
        
        -- Événements reçus du récepteur (Rx)
        got_null        : in  std_logic; -- Impulsion sur réception d'un token NULL valide
        got_fct         : in  std_logic; -- Impulsion sur réception d'un token FCT valide
        got_nchar       : in  std_logic; -- Impulsion sur réception d'un N-Char (donnée)
        err_detect      : in  std_logic; -- Parité, Déconnexion ou Échappement
        
        -- Ordres vers l'émetteur (Tx) et le reste du circuit
        tx_enable       : out std_logic;
        tx_send_null    : out std_logic;
        tx_send_fct     : out std_logic;
        tx_speed_10m    : out std_logic; -- Force 10 Mbps en init
        link_running    : out std_logic  -- État RUN atteint
    );
end entity spw_link_fsm;

architecture rtl of spw_link_fsm is

    type t_state is (S_ERROR_RESET, S_ERROR_WAIT, S_READY, S_STARTED, S_CONNECTING, S_RUN);
    signal state, next_state : t_state;

    -- Constantes de temporisation normalisées :
    -- 6.4 µs  = 320 cycles @ 50 MHz
    -- 12.8 µs = 640 cycles @ 50 MHz
    constant CYCLES_6_4_US  : natural := (CLK_FREQ_HZ / 1_000_000) * 64 / 10;
    constant CYCLES_12_8_US : natural := (CLK_FREQ_HZ / 1_000_000) * 128 / 10;

    signal timer        : natural range 0 to CYCLES_12_8_US;
    signal timer_6_4_done  : std_logic;
    signal timer_12_8_done : std_logic;

begin

    ---------------------------------------------------------------------
    -- Gestion du compteur temporel
    ---------------------------------------------------------------------
    p_timer : process(clk, rst_n)
    begin
        if rst_n = '0' then
            timer <= 0;
        elsif rising_edge(clk) then
            if state /= next_state then
                timer <= 0; -- Reset du timer à chaque changement d'état
            elsif timer < CYCLES_12_8_US then
                timer <= timer + 1;
            end if;
        end if;
    end process;

    timer_6_4_done  <= '1' when timer >= CYCLES_6_4_US  else '0';
    timer_12_8_done <= '1' when timer >= CYCLES_12_8_US else '0';

    ---------------------------------------------------------------------
    -- Registre d'état séquentiel
    ---------------------------------------------------------------------
    p_state_reg : process(clk, rst_n)
    begin
        if rst_n = '0' then
            state <= S_ERROR_RESET;
        elsif rising_edge(clk) then
            state <= next_state;
        end if;
    end process;

    ---------------------------------------------------------------------
    -- Logique combinatoire des transitions
    ---------------------------------------------------------------------
    p_fsm_comb : process(state, link_disable, link_start, auto_start, 
                         got_null, got_fct, got_nchar, err_detect,
                         timer_6_4_done, timer_12_8_done)
    begin
        next_state <= state;

        if link_disable = '1' or err_detect = '1' then
            next_state <= S_ERROR_RESET;
        else
            case state is

                when S_ERROR_RESET =>
                    if timer_6_4_done = '1' then
                        next_state <= S_ERROR_WAIT;
                    end if;

                when S_ERROR_WAIT =>
                    if timer_12_8_done = '1' then
                        next_state <= S_READY;
                    end if;

                when S_READY =>
                    if link_start = '1' or (auto_start = '1' and got_null = '1') then
                        next_state <= S_STARTED;
                    end if;

                when S_STARTED =>
                    if timer_12_8_done = '1' or got_fct = '1' or got_nchar = '1' then
                        next_state <= S_ERROR_RESET;
                    elsif got_null = '1' then
                        next_state <= S_CONNECTING;
                    end if;

                when S_CONNECTING =>
                    if timer_12_8_done = '1' or got_nchar = '1' then
                        next_state <= S_ERROR_RESET;
                    elsif got_fct = '1' then
                        next_state <= S_RUN;
                    end if;

                when S_RUN =>
                    -- Reste en RUN tant qu'aucune erreur physique ou désactivation ne survient
                    null;

                when others =>
                    next_state <= S_ERROR_RESET;

            end case;
        end if;
    end process;

    ---------------------------------------------------------------------
    -- Sorties de commande
    ---------------------------------------------------------------------
    tx_enable    <= '1' when (state = S_STARTED or state = S_CONNECTING or state = S_RUN) else '0';
    tx_send_null <= '1' when (state = S_STARTED or state = S_CONNECTING) else '0';
    tx_send_fct  <= '1' when (state = S_CONNECTING or state = S_RUN) else '0';
    tx_speed_10m <= '1' when (state = S_STARTED or state = S_CONNECTING) else '0';
    link_running <= '1' when (state = S_RUN) else '0';

end architecture rtl;
