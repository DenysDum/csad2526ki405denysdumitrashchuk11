LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
use ieee.numeric_std.all;

ENTITY Master_tb IS
END Master_tb;

ARCHITECTURE behavior OF Master_tb IS 

    -- Component Declaration for the Unit Under Test (UUT)
    COMPONENT i2c_master
        GENERIC (
            G_SYSTEM_CLK : natural := 50_000_000; 
            G_I2C_CLK    : natural := 100_000      
        );
    PORT(
            i_clk : IN  std_logic;
            i_rst_n : IN  std_logic; 
            i_start : IN  std_logic;
            i_addr : IN  std_logic_vector(6 downto 0);
            i_rw : IN  std_logic;
            i_data_wr : IN  std_logic_vector(7 downto 0);
            o_data_rd : OUT  std_logic_vector(7 downto 0);
            o_busy : OUT  std_logic;
            o_ack_err : OUT  std_logic;
            io_scl : INOUT  std_logic;
            io_sda : INOUT  std_logic
        );
END COMPONENT;
    

    --Inputs
    signal i_clk : std_logic := '0';
    signal i_rst_n : std_logic := '0';
signal i_start : std_logic := '0';
    signal i_addr : std_logic_vector(6 downto 0) := (others => '0');
signal i_rw : std_logic := '0';
    signal i_data_wr : std_logic_vector(7 downto 0) := (others => '0');
--BiDirs
    signal io_scl : std_logic;
    signal io_sda : std_logic;
--Outputs
    signal o_data_rd : std_logic_vector(7 downto 0);
    signal o_busy : std_logic;
    signal o_ack_err : std_logic;

-- Clock period definitions
    -- Set to 20 ns to match the 50MHz G_SYSTEM_CLK generic
    constant i_clk_period : time := 20 ns;

-- Testbench constants
    constant C_SLAVE_ADDR    : std_logic_vector(6 downto 0) := "1010000";

BEGIN

    -- Instantiate the Unit Under Test (UUT)
    uut: i2c_master 
    GENERIC MAP (
        G_SYSTEM_CLK => 50_000_000,
        G_I2C_CLK    => 100_000
    )
    PORT MAP (
        i_clk => i_clk,
        i_rst_n => i_rst_n,
        i_start => i_start,
        i_addr => i_addr,
    i_rw => i_rw,
        i_data_wr => i_data_wr,
        o_data_rd => o_data_rd,
        o_busy => o_busy,
        o_ack_err => o_ack_err,
        io_scl => io_scl,
        io_sda => io_sda
    );

io_scl <= 'H';
io_sda <= 'H';

    -- Clock process definitions
    i_clk_process :process
    begin
        i_clk <= '0';
    wait for i_clk_period/2;
        i_clk <= '1';
        wait for i_clk_period/2;
    end process;

-- Stimulus process
    stim_proc: process
    begin       
        -- 1. Hold reset state for 100 ns.
i_rst_n <= '0';
        wait for 100 ns;    
i_rst_n <= '1'; -- Release reset
        wait for i_clk_period*10; 

-- 2. --- Test 1: Write Transaction (Must fail with NACK) ---
        report "TB: --- Test 1: Master Write ---";
i_addr    <= C_SLAVE_ADDR;
i_rw      <= '0'; -- Write
        i_data_wr <= x"A5";
        
-- Send start pulse
        i_start <= '1';
        wait for i_clk_period;
        i_start <= '0';

        wait until o_busy = '0';
        report "TB: Master is free. Write complete.";

        -- Check for NACK
        assert o_ack_err = '1'
            report "TB TEST 1 FAILED"
            severity error;
        
		wait for 1 us; -- Wait a bit

        -- 3. --- Test 2: Read Transaction (Must fail with NACK) ---
        report "TB: --- Test 2: Master Read";
			i_addr    <= C_SLAVE_ADDR;
			i_rw      <= '1'; -- Read
        
        -- Send start pulse
			i_start <= '1';
        wait for i_clk_period;
        i_start <= '0';
        
        -- Wait for the transaction to complete
			wait until o_busy = '0';
        report "TB: Master is free. Read complete.";

        -- Check for NACK
        assert o_ack_err = '1'
            report "TB TEST 2 FAILED"
            severity error;

        wait for 1 us; -- Wait a bit
        
        wait; -- End of simulation
    end process;

END;