library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master is
    generic (
        -- Частота системного годинника (напр. 50 МГц з ПЛІС)
        G_SYSTEM_CLK : natural := 50_000_000; 
        -- Цільова частота шини I2C (напр. 100 кГц)
        G_I2C_CLK    : natural := 100_000      
    );
    port (
        -- --- Системні сигнали ---
        i_clk     : in  std_logic; -- Вхідний системний годинник
        i_rst_n   : in  std_logic; -- Асинхронний скид (активний низький)

        -- --- Інтерфейс керування (від вашої FSM або CPU) ---
        i_start   : in  std_logic; -- '1' для початку транзакції
        i_addr    : in  std_logic_vector(6 downto 0); -- 7-бітна адреса Slave
        i_rw      : in  std_logic; -- '0' = Write (Запис), '1' = Read (Читання)
        i_data_wr : in  std_logic_vector(7 downto 0); -- Дані для запису в Slave
        o_data_rd : out std_logic_vector(7 downto 0); -- Дані, що прочитані зі Slave
        o_busy    : out std_logic; -- '1', поки транзакція активна
        o_ack_err : out std_logic; -- '1', якщо отримано NACK (помилка)

        -- --- I2C Шина ---
        -- Це 'inout', оскільки Master має як керувати (drive), 
        -- так і слухати (read) ці лінії.
        io_scl    : inout std_logic;
        io_sda    : inout std_logic
    );
end entity i2c_master;

architecture rtl of i2c_master is
    -- --- Константи ---
    -- Розрахунок прескалера. Нам потрібно 4 "тіки" на один період SCL 
    -- (SCL low, SCL rising, SCL high, SCL falling).
    constant C_CLK_DIV_COUNT : natural := (G_SYSTEM_CLK / (G_I2C_CLK * 4));

    -- --- Стани FSM ---
    type t_state is (
        IDLE,             -- 0. Очікування команди i_start
        START_1,          -- 1. Генерація СТАРТ: SCL=H, SDA=L
        START_2,          -- 2. Генерація СТАРТ: SCL=L, SDA=L
        SEND_ADDR,        -- 3. Відправка 8 біт (Адреса + R/W)
        WAIT_ACK_1,       -- 4. Очікування ACK (SCL=L, відпускаємо SDA)
        WAIT_ACK_2,       -- 5. Очікування ACK (SCL=H, читаємо SDA)
        WAIT_ACK_3,       -- 6. Очікування ACK (SCL=L, аналізуємо ACK)
        
        -- Стани для ЗАПИСУ (Write, R/W='0')
        SEND_BYTE_WR,     -- 7. Відправка 8 біт даних
        WAIT_ACK_BYTE_1,  -- 8. Очікування ACK даних (SCL=L, відпускаємо SDA)
        WAIT_ACK_BYTE_2,  -- 9. Очікування ACK даних (SCL=H, читаємо SDA)
        WAIT_ACK_BYTE_3,  -- 10. Очікування ACK даних (SCL=L, аналізуємо)

        -- Стани для ЧИТАННЯ (Read, R/W='1')
        RECV_BIT_SCL_HI,  -- 11. Прийом біта (SCL=H, Master читає SDA)
        RECV_BIT_SCL_LO,  -- 12. Прийом біта (SCL=L, Master зберігає біт)
        SEND_NACK_1,      -- 13. Надсилаємо NACK (SCL=L, Master виставляє SDA=H)
        SEND_NACK_2,      -- 14. Надсилаємо NACK (SCL=H, Slave читає NACK)

        -- Стани СТОП
        STOP_1,           -- 15. Генерація СТОП: SCL=L, SDA=L
        STOP_2,           -- 16. Генерація СТОП: SCL=H, SDA=L
        STOP_3            -- 17. Генерація СТОП: SCL=H, SDA=H (умова СТОП)
    );

    -- --- Внутрішні сигнали ---
    signal s_state      : t_state := IDLE;  -- Поточний стан FSM
    signal s_clk_div    : natural range 0 to C_CLK_DIV_COUNT - 1 := 0; -- Лічильник прескалера
    signal s_clk_en     : std_logic := '0'; -- 'Тік' для FSM (один раз за чверть періоду SCL)
    signal s_bit_count  : integer range 0 to 7 := 0; -- Лічильник біт (для 8 біт)

    -- Регістри для зберігання параметрів поточної транзакції
    signal s_addr_reg   : std_logic_vector(6 downto 0);
    signal s_rw_reg     : std_logic;
    signal s_data_wr_reg: std_logic_vector(7 downto 0);
    signal s_data_rd_reg: std_logic_vector(7 downto 0); -- Буфер для прочитаних даних
    signal s_shift_reg  : std_logic_vector(7 downto 0); -- Зсувний регістр (для Tx і Rx)

    -- Керування tristate-буферами (активний низький '_n')
    signal s_scl_en_n   : std_logic := '1'; -- '0' = Master керує SCL
    signal s_sda_en_n   : std_logic := '1'; -- '0' = Master керує SDA
    signal s_scl_out    : std_logic := '1'; -- Значення, яке Master виставляє на SCL
    signal s_sda_out    : std_logic := '1'; -- Значення, яке Master виставляє на SDA

    -- Сигнали стану
    signal s_busy       : std_logic := '0'; -- Внутрішній сигнал o_busy
    signal s_ack_err    : std_logic := '0'; -- Внутрішній сигнал o_ack_err
    signal s_ack_in     : std_logic;      -- Збережене значення SDA (для ACK або прийому даних)

begin

    --=========================================================================
    -- 1. Логіка прескалера
    -- Генерує `s_clk_en` (один 'тік') кожні C_CLK_DIV_COUNT циклів i_clk.
    -- Це дає нам 4 'тіки' на один повний період SCL.
    --=========================================================================
    process (i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            s_clk_div <= 0;
            s_clk_en  <= '0';
        elsif rising_edge(i_clk) then
            s_clk_en <= '0';
            if s_clk_div = C_CLK_DIV_COUNT - 1 then
                s_clk_div <= 0;
                s_clk_en  <= '1'; -- Генеруємо 'тік'
            else
                s_clk_div <= s_clk_div + 1;
            end if;
        end if;
    end process;

    -- 2. Скінченний автомат (FSM) - Синхронна логіка
    -- Працює на кожному `rising_edge(i_clk)`.
    process (i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            -- Скидання всіх сигналів у початковий стан
            s_state       <= IDLE;
            s_busy        <= '0';
            s_ack_err     <= '0';
            s_bit_count   <= 0;
            s_shift_reg   <= (others => '0');
            s_data_rd_reg <= (others => '0');
        
        elsif rising_edge(i_clk) then
            
            -- Зчитуємо вхід SDA, коли SCL гарантовано високий (в станах WAIT_ACK_2 і RECV_BIT_SCL_HI)
            -- Це важливо, оскільки FSM змінює стани на 'тіках' (s_clk_en),
            -- а стан SCL=H тримається між тіками.
            if s_state = WAIT_ACK_2 or s_state = RECV_BIT_SCL_HI then
                 s_ack_in <= io_sda; 
            end if;

            -- FSM змінює стани лише на 'тік' прескалера (s_clk_en = '1'),
            -- за винятком стану IDLE, який має миттєво реагувати на i_start.
            if s_clk_en = '1' or s_state = IDLE then 
                
                case s_state is
                    
                    -- --- 0. Очікування ---
                    when IDLE =>
                        s_busy    <= '0';
                        s_ack_err <= '0';
                        if i_start = '1' then
                            -- Отримали команду, захоплюємо параметри транзакції
                            s_addr_reg    <= i_addr;
                            s_rw_reg      <= i_rw;
                            s_data_wr_reg <= i_data_wr;
                            s_busy        <= '1'; -- Починаємо роботу
                            s_ack_err     <= '0';
                            s_data_rd_reg <= (others => '0'); -- Скидаємо буфер читання
                            s_state       <= START_1; -- Перехід до СТАРТ
                        end if;

                    -- --- 1-2. Генерація СТАРТ ---
                    when START_1 => 
                        s_state <= START_2; -- (SCL=H, SDA=L -> SCL=L, SDA=L)
                    when START_2 => 
                        -- Завантажуємо 7 біт адреси + 1 біт R/W у зсувний регістр
                        s_shift_reg <= s_addr_reg & s_rw_reg; 
                        s_bit_count <= 7; -- Починаємо з MSB (біт 7)
                        s_state     <= SEND_ADDR;

                    -- --- 3. Відправка Адреси/Даних ---
                    when SEND_ADDR => 
                        if s_bit_count = 0 then
                            s_state <= WAIT_ACK_1; -- Всі 8 біт надіслано, чекаємо ACK
                        else
                            s_bit_count <= s_bit_count - 1; -- Наступний біт
                            s_shift_reg <= s_shift_reg(6 downto 0) & '0'; -- Зсув
                        end if;
                        -- (Комбінаційна логіка виставить s_shift_reg(7) на SDA)

                    -- --- 4-6. Очікування ACK від Slave ---
                    when WAIT_ACK_1 => s_state <= WAIT_ACK_2; -- SCL=L, відпускаємо SDA
                    when WAIT_ACK_2 => s_state <= WAIT_ACK_3; -- SCL=H, читаємо SDA (вже в s_ack_in)
                    
                    when WAIT_ACK_3 => -- SCL=L, аналізуємо отриманий ACK
                        if s_ack_in = '1' then -- '1' == NACK
                            s_ack_err <= '1'; -- Помилка
                            s_state   <= STOP_1; -- Аборт транзакції
                        
                        -- '0' == ACK, продовжуємо
                        elsif s_rw_reg = '0' then -- Це була операція ЗАПИСУ
                            s_shift_reg <= s_data_wr_reg; -- Завантажуємо дані для запису
                            s_bit_count <= 7;
                            s_state     <= SEND_BYTE_WR;
                        else -- Це була операція ЧИТАННЯ
                            s_shift_reg <= (others => '0'); -- Готуємо буфер для прийому
                            s_bit_count <= 7;
                            s_state     <= RECV_BIT_SCL_HI; -- Починаємо прийом (SCL high)
                        end if;

                    -- --- 7. Стани ЗАПИСУ (Write) ---
                    when SEND_BYTE_WR => 
                        if s_bit_count = 0 then
                            s_state <= WAIT_ACK_BYTE_1; -- Байт надіслано, чекаємо ACK
                        else
                            s_bit_count <= s_bit_count - 1;
                            s_shift_reg <= s_shift_reg(6 downto 0) & '0';
                        end if;
                    
                    -- 8-10. Очікування ACK після байту даних (аналогічно 4-6)
                    when WAIT_ACK_BYTE_1 => s_state <= WAIT_ACK_BYTE_2;
                    when WAIT_ACK_BYTE_2 => s_state <= WAIT_ACK_BYTE_3;
                    when WAIT_ACK_BYTE_3 =>
                        if s_ack_in = '1' then -- NACK (напр., буфер Slave повний)
                             s_ack_err <= '1';
                        end if;
                        s_state <= STOP_1; -- Завершуємо (для простоти, лише 1 байт)

                    -- --- 11-12. Стани ЧИТАННЯ (Read) ---
                    when RECV_BIT_SCL_HI => -- SCL=H. (SDA вже прочитано в s_ack_in)
                        s_state <= RECV_BIT_SCL_LO;
                    
                    when RECV_BIT_SCL_LO => -- SCL=L.
                        s_shift_reg(s_bit_count) <= s_ack_in; -- Зберігаємо прочитаний біт
                        
                        if s_bit_count = 0 then
                            s_data_rd_reg <= s_shift_reg; -- Зберігаємо прийнятий байт
                            s_state <= SEND_NACK_1;       -- Байт отримано, надсилаємо NACK (кінець читання)
                        else
                            s_bit_count <= s_bit_count - 1;
                            s_state     <= RECV_BIT_SCL_HI; -- Готові до наступного біта
                        end if;
                        
                    -- --- 13-14. Надсилання NACK (кінець читання) ---
                    when SEND_NACK_1 => -- SCL=L. Master виставляє SDA=H (NACK)
                        s_state <= SEND_NACK_2;
                    
                    when SEND_NACK_2 => -- SCL=H. Slave читає NACK
                        s_state <= STOP_1; -- Переходимо до СТОП

                    -- --- 15-17. Генерація СТОП ---
                    when STOP_1 => s_state <= STOP_2;
                    when STOP_2 => s_state <= STOP_3;
                    when STOP_3 => s_state <= IDLE; -- Готово, повертаємось в IDLE

                end case;
            end if;
        end if;
    end process;

    -- 3. Комбінаційна логіка - Керування виходами SCL/SDA
    -- Цей процес визначає, що виставляти на SCL/SDA в кожному стані FSM.
    process (s_state, s_shift_reg)
    begin
        -- Значення за замовчуванням: лінії відпущені (високий імпеданс)
        s_scl_out  <= '1'; s_scl_en_n <= '1'; 
        s_sda_out  <= '1'; s_sda_en_n <= '1'; 

        case s_state is
            when IDLE => null; -- Шина вільна (Z)

            when START_1 => -- Умова СТАРТ: SCL=H, SDA=L
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_out  <= '0'; s_sda_en_n <= '0';

            when START_2 | STOP_1 => -- SCL=L, SDA=L
                s_scl_out  <= '0'; s_scl_en_n <= '0';
                s_sda_out  <= '0'; s_sda_en_n <= '0';
                
            when SEND_ADDR | SEND_BYTE_WR =>
                -- (Спрощено: SCL=L, виставляємо біт)
                -- Повноцінна логіка мала б 4 фази для SCL=L, SCL=H
                s_scl_out  <= '0'; s_scl_en_n <= '0'; 
                s_sda_out  <= s_shift_reg(7); s_sda_en_n <= '0'; -- Виставляємо MSB
                
            when WAIT_ACK_1 | WAIT_ACK_3 | WAIT_ACK_BYTE_1 | WAIT_ACK_BYTE_3 => 
                -- SCL=L, відпускаємо SDA
                s_scl_out  <= '0'; s_scl_en_n <= '0';
                s_sda_en_n <= '1'; -- 'Z' (слухаємо)

            when WAIT_ACK_2 | WAIT_ACK_BYTE_2 => 
                -- SCL=H, відпускаємо SDA (слухаємо ACK)
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_en_n <= '1'; -- 'Z'
            
            when RECV_BIT_SCL_HI => -- Читання: Master генерує SCL=H, слухає SDA
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_en_n <= '1'; -- 'Z'

            when RECV_BIT_SCL_LO => -- Читання: Master генерує SCL=L, слухає SDA
                s_scl_out  <= '0'; s_scl_en_n <= '0';
                s_sda_en_n <= '1'; -- 'Z'
            
            when SEND_NACK_1 => -- NACK: SCL=L, Master виставляє SDA=H
                s_scl_out  <= '0'; s_scl_en_n <= '0';
                s_sda_out  <= '1'; s_sda_en_n <= '0'; -- Керуємо SDA

            when SEND_NACK_2 => -- NACK: SCL=H, Master тримає SDA=H
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_out  <= '1'; s_sda_en_n <= '0'; 
            
            when STOP_2 => -- Умова СТОП (фаза 2): SCL=H, SDA=L
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_out  <= '0'; s_sda_en_n <= '0';

            when STOP_3 => -- Умова СТОП (фаза 3): SCL=H, SDA=H
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_out  <= '1'; s_sda_en_n <= '0';
        end case;
    end process;

    io_scl <= s_scl_out when s_scl_en_n = '0' else 'Z';
    io_sda <= s_sda_out when s_sda_en_n = '0' else 'Z';

    o_busy    <= s_busy;
    o_ack_err <= s_ack_err;
    o_data_rd <= s_data_rd_reg;

end architecture rtl;