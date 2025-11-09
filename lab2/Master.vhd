library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master is
    generic (
        -- System clock frequency (e.g., 50 MHz from the FPGA)
        G_SYSTEM_CLK : natural := 50_000_000; 
        -- Target I2C bus frequency (e.g., 100 kHz)
        G_I2C_CLK    : natural := 100_000      
    );
    port (
        -- --- System Signals ---
        i_clk     : in  std_logic; -- System clock input
        i_rst_n   : in  std_logic; -- Asynchronous reset (active low)

        -- --- Control Interface (from your FSM or CPU) ---
        i_start   : in  std_logic; -- '1' to start a transaction
        i_addr    : in  std_logic_vector(6 downto 0); -- 7-bit Slave address
        i_rw      : in  std_logic; -- '0' = Write, '1' = Read
        i_data_wr : in  std_logic_vector(7 downto 0); -- Data to write to Slave
        o_data_rd : out std_logic_vector(7 downto 0); -- Data read from Slave
        o_busy    : out std_logic; -- '1' while a transaction is active
        o_ack_err : out std_logic; -- '1' if a NACK was received (error)

        -- --- I2C Bus ---
        -- These are 'inout' because the Master must both drive 
        -- and read these lines.
        io_scl    : inout std_logic;
        io_sda    : inout std_logic
    );
end entity i2c_master;

architecture rtl of i2c_master is
    -- --- Constants ---
    -- Prescaler calculation. We need 4 "ticks" per SCL period
    -- (SCL low, SCL rising, SCL high, SCL falling).
    constant C_CLK_DIV_COUNT : natural := (G_SYSTEM_CLK / (G_I2C_CLK * 4));

    -- --- FSM States ---
    type t_state is (
        IDLE,             -- 0. Waiting for i_start command
        START_1,          -- 1. Generate START: SCL=H, SDA=L
        START_2,          -- 2. Generate START: SCL=L, SDA=L
        SEND_ADDR,        -- 3. Send 8 bits (Address + R/W)
        WAIT_ACK_1,       -- 4. Wait for ACK (SCL=L, release SDA)
        WAIT_ACK_2,       -- 5. Wait for ACK (SCL=H, read SDA)
        WAIT_ACK_3,       -- 6. Wait for ACK (SCL=L, analyze ACK)
        
        -- States for WRITE (R/W='0')
        SEND_BYTE_WR,     -- 7. Send 8 bits of data
        WAIT_ACK_BYTE_1,  -- 8. Wait for data ACK (SCL=L, release SDA)
        WAIT_ACK_BYTE_2,  -- 9. Wait for data ACK (SCL=H, read SDA)
        WAIT_ACK_BYTE_3,  -- 10. Wait for data ACK (SCL=L, analyze)

        -- States for READ (R/W='1')
        RECV_BIT_SCL_HI,  -- 11. Receive bit (SCL=H, Master reads SDA)
        RECV_BIT_SCL_LO,  -- 12. Receive bit (SCL=L, Master stores bit)
        SEND_NACK_1,      -- 13. Send NACK (SCL=L, Master drives SDA=H)
        SEND_NACK_2,      -- 14. Send NACK (SCL=H, Slave reads NACK)

        -- STOP States
        STOP_1,           -- 15. Generate STOP: SCL=L, SDA=L
        STOP_2,           -- 16. Generate STOP: SCL=H, SDA=L
        STOP_3            -- 17. Generate STOP: SCL=H, SDA=H (Stop condition)
    );

    -- --- Internal Signals ---
    signal s_state      : t_state := IDLE;  -- Current FSM state
    signal s_clk_div    : natural range 0 to C_CLK_DIV_COUNT - 1 := 0; -- Prescaler counter
    signal s_clk_en     : std_logic := '0'; -- 'Tick' for the FSM (once per SCL quarter-period)
    signal s_bit_count  : integer range 0 to 7 := 0; -- Bit counter (for 8 bits)

    -- Registers to hold current transaction parameters
    signal s_addr_reg   : std_logic_vector(6 downto 0);
    signal s_rw_reg     : std_logic;
    signal s_data_wr_reg: std_logic_vector(7 downto 0);
    signal s_data_rd_reg: std_logic_vector(7 downto 0); -- Buffer for read data
    signal s_shift_reg  : std_logic_vector(7 downto 0); -- Universal shift register (for Tx and Rx)

    -- Tristate buffer control (active low '_n')
    signal s_scl_en_n   : std_logic := '1'; -- '0' = Master drives SCL
    signal s_sda_en_n   : std_logic := '1'; -- '0' = Master drives SDA
    signal s_scl_out    : std_logic := '1'; -- Value Master drives on SCL
    signal s_sda_out    : std_logic := '1'; -- Value Master drives on SDA

    -- Status signals
    signal s_busy       : std_logic := '0'; -- Internal signal for o_busy
    signal s_ack_err    : std_logic := '0'; -- Internal signal for o_ack_err
    signal s_ack_in     : std_logic;      -- Stored value of SDA (for ACK or data receive)

begin

    -- 1. Prescaler Logic
    -- Generates `s_clk_en` (one 'tick') every C_CLK_DIV_COUNT cycles of i_clk.
    -- This gives us 4 'ticks' per full SCL period.
    process (i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            s_clk_div <= 0;
            s_clk_en  <= '0';
        elsif rising_edge(i_clk) then
            s_clk_en <= '0';
            if s_clk_div = C_CLK_DIV_COUNT - 1 then
                s_clk_div <= 0;
                s_clk_en  <= '1'; -- Generate 'tick'
            else
                s_clk_div <= s_clk_div + 1;
            end if;
        end if;
    end process;

    -- 2. Finite State Machine (FSM) - Synchronous Logic
    -- Runs on every `rising_edge(i_clk)`.
    process (i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            -- Reset all signals to their initial state
            s_state       <= IDLE;
            s_busy        <= '0';
            s_ack_err     <= '0';
            s_bit_count   <= 0;
            s_shift_reg   <= (others => '0');
            s_data_rd_reg <= (others => '0');
        
        elsif rising_edge(i_clk) then
            
            -- Read the SDA input when SCL is guaranteed high (in WAIT_ACK_2 and RECV_BIT_SCL_HI states)
            -- This is important because the FSM changes states on 'ticks' (s_clk_en),
            -- but the SCL=H state is held between ticks.
            if s_state = WAIT_ACK_2 or s_state = RECV_BIT_SCL_HI then
                 s_ack_in <= io_sda; 
            end if;

            -- The FSM only changes states on the prescaler 'tick' (s_clk_en = '1'),
            -- except for the IDLE state, which must react to i_start immediately.
            if s_clk_en = '1' or s_state = IDLE then 
                
                case s_state is
                    
                    -- --- 0. Idle ---
                    when IDLE =>
                        s_busy    <= '0';
                        s_ack_err <= '0';
                        if i_start = '1' then
                            -- Command received, latch transaction parameters
                            s_addr_reg    <= i_addr;
                            s_rw_reg      <= i_rw;
                            s_data_wr_reg <= i_data_wr;
                            s_busy        <= '1'; -- We are now busy
                            s_ack_err     <= '0';
                            s_data_rd_reg <= (others => '0'); -- Clear read buffer
                            s_state       <= START_1; -- Transition to START
                        end if;

                    -- --- 1-2. Generate START ---
                    when START_1 => 
                        s_state <= START_2; -- (SCL=H, SDA=L -> SCL=L, SDA=L)
                    when START_2 => 
                        -- Load 7-bit address + 1-bit R/W into the shift register
                        s_shift_reg <= s_addr_reg & s_rw_reg; 
                        s_bit_count <= 7; -- Start with MSB (bit 7)
                        s_state     <= SEND_ADDR;

                    -- --- 3. Send Address/Data ---
                    when SEND_ADDR => 
                        if s_bit_count = 0 then
                            s_state <= WAIT_ACK_1; -- All 8 bits sent, wait for ACK
                        else
                            s_bit_count <= s_bit_count - 1; -- Next bit
                            s_shift_reg <= s_shift_reg(6 downto 0) & '0'; -- Shift
                        end if;
                        -- (Combinatorial logic will output s_shift_reg(7) on SDA)

                    -- --- 4-6. Wait for ACK from Slave ---
                    when WAIT_ACK_1 => s_state <= WAIT_ACK_2; -- SCL=L, release SDA
                    when WAIT_ACK_2 => s_state <= WAIT_ACK_3; -- SCL=H, read SDA (already in s_ack_in)
                    
                    when WAIT_ACK_3 => -- SCL=L, analyze the received ACK
                        if s_ack_in = '1' then -- '1' == NACK
                            s_ack_err <= '1'; -- Error
                            s_state   <= STOP_1; -- Abort transaction
                        
                        -- '0' == ACK, continue
                        elsif s_rw_reg = '0' then -- It was a WRITE operation
                            s_shift_reg <= s_data_wr_reg; -- Load data to be written
                            s_bit_count <= 7;
                            s_state     <= SEND_BYTE_WR;
                        else -- It was a READ operation
                            s_shift_reg <= (others => '0'); -- Prepare buffer for reception
                            s_bit_count <= 7;
                            s_state     <= RECV_BIT_SCL_HI; -- Start receiving (SCL high)
                        end if;

                    -- --- 7. WRITE States ---
                    when SEND_BYTE_WR => 
                        if s_bit_count = 0 then
                            s_state <= WAIT_ACK_BYTE_1; -- Byte sent, wait for ACK
                        else
                            s_bit_count <= s_bit_count - 1;
                            s_shift_reg <= s_shift_reg(6 downto 0) & '0';
                        end if;
                    
                    -- 8-10. Wait for ACK after data byte (similar to 4-6)
                    when WAIT_ACK_BYTE_1 => s_state <= WAIT_ACK_BYTE_2;
                    when WAIT_ACK_BYTE_2 => s_state <= WAIT_ACK_BYTE_3;
                    when WAIT_ACK_BYTE_3 =>
                        if s_ack_in = '1' then -- NACK (e.g., Slave buffer full)
                             s_ack_err <= '1';
                        end if;
                        s_state <= STOP_1; -- Terminate (for simplicity, only 1 byte)

                    -- --- 11-12. READ States ---
                    when RECV_BIT_SCL_HI => -- SCL=H. (SDA already read into s_ack_in)
                        s_state <= RECV_BIT_SCL_LO;
                    
                    when RECV_BIT_SCL_LO => -- SCL=L.
                        s_shift_reg(s_bit_count) <= s_ack_in; -- Store the read bit
                        
                        if s_bit_count = 0 then
                            s_data_rd_reg <= s_shift_reg; -- Store the received byte
                            s_state <= SEND_NACK_1;       -- Byte received, send NACK (end of read)
                        else
                            s_bit_count <= s_bit_count - 1;
                            s_state     <= RECV_BIT_SCL_HI; -- Ready for the next bit
                        end if;
                        
                    -- --- 13-14. Send NACK (end of read) ---
                    when SEND_NACK_1 => -- SCL=L. Master drives SDA=H (NACK)
                        s_state <= SEND_NACK_2;
                    
                    when SEND_NACK_2 => -- SCL=H. Slave reads NACK
                        s_state <= STOP_1; -- Transition to STOP

                    -- --- 15-17. Generate STOP ---
                    when STOP_1 => s_state <= STOP_2;
                    when STOP_2 => s_state <= STOP_3;
                    when STOP_3 => s_state <= IDLE; -- Done, return to IDLE

                end case;
            end if;
        end if;
    end process;

    -- 3. Combinatorial Logic - SCL/SDA Output Control
    -- This process determines what to drive on SCL/SDA in each FSM state.
    process (s_state, s_shift_reg)
    begin
        -- Default values: lines released (high impedance)
        s_scl_out  <= '1'; s_scl_en_n <= '1'; 
        s_sda_out  <= '1'; s_sda_en_n <= '1'; 

        case s_state is
            when IDLE => null; -- Bus free (Z)

            when START_1 => -- START condition: SCL=H, SDA=L
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_out  <= '0'; s_sda_en_n <= '0';

            when START_2 | STOP_1 => -- SCL=L, SDA=L
                s_scl_out  <= '0'; s_scl_en_n <= '0';
                s_sda_out  <= '0'; s_sda_en_n <= '0';
                
            when SEND_ADDR | SEND_BYTE_WR =>
                -- (Simplified: SCL=L, set bit)
                -- A full implementation would have 4 phases for SCL=L, SCL=H
                s_scl_out  <= '0'; s_scl_en_n <= '0'; 
                s_sda_out  <= s_shift_reg(7); s_sda_en_n <= '0'; -- Output MSB
                
            when WAIT_ACK_1 | WAIT_ACK_3 | WAIT_ACK_BYTE_1 | WAIT_ACK_BYTE_3 => 
                -- SCL=L, release SDA
                s_scl_out  <= '0'; s_scl_en_n <= '0';
                s_sda_en_n <= '1'; -- 'Z' (listen)

            when WAIT_ACK_2 | WAIT_ACK_BYTE_2 => 
                -- SCL=H, release SDA (listen for ACK)
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_en_n <= '1'; -- 'Z'
            
            when RECV_BIT_SCL_HI => -- Read: Master generates SCL=H, listens to SDA
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_en_n <= '1'; -- 'Z'

            when RECV_BIT_SCL_LO => -- Read: Master generates SCL=L, listens to SDA
                s_scl_out  <= '0'; s_scl_en_n <= '0';
                s_sda_en_n <= '1'; -- 'Z'
            
            when SEND_NACK_1 => -- NACK: SCL=L, Master drives SDA=H
                s_scl_out  <= '0'; s_scl_en_n <= '0';
                s_sda_out  <= '1'; s_sda_en_n <= '0'; -- Drive SDA

            when SEND_NACK_2 => -- NACK: SCL=H, Master holds SDA=H
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_out  <= '1'; s_sda_en_n <= '0'; 
            
            when STOP_2 => -- STOP condition (phase 2): SCL=H, SDA=L
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_out  <= '0'; s_sda_en_n <= '0';

            when STOP_3 => -- STOP condition (phase 3): SCL=H, SDA=H
                s_scl_out  <= '1'; s_scl_en_n <= '0';
                s_sda_out  <= '1'; s_sda_en_n <= '0';
        end case;
    end process;

    -- 4. INOUT Port Control (Tristate Buffers)
    io_scl <= s_scl_out when s_scl_en_n = '0' else 'Z';
    io_sda <= s_sda_out when s_sda_en_n = '0' else 'Z';

    -- 5. Output Signals
    o_busy    <= s_busy;
    o_ack_err <= s_ack_err;
    o_data_rd <= s_data_rd_reg; -- Output the read data

end architecture rtl;