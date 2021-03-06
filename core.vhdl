library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.common.all;
use work.wishbone_types.all;

entity core is
    generic (
        SIM : boolean := false;
	DISABLE_FLATTEN : boolean := false;
        EX1_BYPASS : boolean := true;
	ALT_RESET_ADDRESS : std_ulogic_vector(63 downto 0) := (others => '0');
        LOG_LENGTH : natural := 512
        );
    port (
        clk          : in std_ulogic;
        rst          : in std_ulogic;

	-- Alternate reset (0xffff0000) for use by DRAM init fw
	alt_reset    : in std_ulogic;

	-- Wishbone interface
        wishbone_insn_in  : in wishbone_slave_out;
        wishbone_insn_out : out wishbone_master_out;

        wishbone_data_in  : in wishbone_slave_out;
        wishbone_data_out : out wishbone_master_out;

	dmi_addr	: in std_ulogic_vector(3 downto 0);
	dmi_din	        : in std_ulogic_vector(63 downto 0);
	dmi_dout	: out std_ulogic_vector(63 downto 0);
	dmi_req	        : in std_ulogic;
	dmi_wr		: in std_ulogic;
	dmi_ack	        : out std_ulogic;

	ext_irq		: in std_ulogic;

	terminated_out   : out std_logic
        );
end core;

architecture behave of core is
    -- icache signals
    signal fetch1_to_icache : Fetch1ToIcacheType;
    signal icache_to_decode1 : IcacheToDecode1Type;
    signal mmu_to_icache : MmuToIcacheType;

    -- decode signals
    signal decode1_to_decode2: Decode1ToDecode2Type;
    signal decode1_to_fetch1: Decode1ToFetch1Type;
    signal decode2_to_execute1: Decode2ToExecute1Type;

    -- register file signals
    signal register_file_to_decode2: RegisterFileToDecode2Type;
    signal decode2_to_register_file: Decode2ToRegisterFileType;
    signal writeback_to_register_file: WritebackToRegisterFileType;

    -- CR file signals
    signal decode2_to_cr_file: Decode2ToCrFileType;
    signal cr_file_to_decode2: CrFileToDecode2Type;
    signal writeback_to_cr_file: WritebackToCrFileType;

    -- execute signals
    signal execute1_to_writeback: Execute1ToWritebackType;
    signal execute1_to_fetch1: Execute1ToFetch1Type;

    -- load store signals
    signal execute1_to_loadstore1: Execute1ToLoadstore1Type;
    signal loadstore1_to_execute1: Loadstore1ToExecute1Type;
    signal loadstore1_to_writeback: Loadstore1ToWritebackType;
    signal loadstore1_to_mmu: Loadstore1ToMmuType;
    signal mmu_to_loadstore1: MmuToLoadstore1Type;

    -- dcache signals
    signal loadstore1_to_dcache: Loadstore1ToDcacheType;
    signal dcache_to_loadstore1: DcacheToLoadstore1Type;
    signal mmu_to_dcache: MmuToDcacheType;
    signal dcache_to_mmu: DcacheToMmuType;

    -- local signals
    signal fetch1_stall_in : std_ulogic;
    signal icache_stall_out : std_ulogic;
    signal icache_stall_in : std_ulogic;
    signal decode1_stall_in : std_ulogic;
    signal decode1_busy     : std_ulogic;
    signal decode2_busy_in : std_ulogic;
    signal decode2_stall_out : std_ulogic;
    signal ex1_icache_inval: std_ulogic;
    signal ex1_busy_out: std_ulogic;
    signal dcache_stall_out: std_ulogic;

    signal flush: std_ulogic;
    signal decode1_flush: std_ulogic;
    signal fetch1_flush: std_ulogic;

    signal complete: std_ulogic;
    signal terminate: std_ulogic;
    signal core_rst: std_ulogic;
    signal icache_inv: std_ulogic;

    -- Delayed/Latched resets and alt_reset
    signal rst_fetch1  : std_ulogic := '1';
    signal rst_fetch2  : std_ulogic := '1';
    signal rst_icache  : std_ulogic := '1';
    signal rst_dcache  : std_ulogic := '1';
    signal rst_dec1    : std_ulogic := '1';
    signal rst_dec2    : std_ulogic := '1';
    signal rst_ex1     : std_ulogic := '1';
    signal rst_ls1     : std_ulogic := '1';
    signal rst_dbg     : std_ulogic := '1';
    signal alt_reset_d : std_ulogic;

    signal sim_cr_dump: std_ulogic;

    -- Debug actions
    signal dbg_core_stop: std_ulogic;
    signal dbg_core_rst: std_ulogic;
    signal dbg_icache_rst: std_ulogic;

    signal dbg_gpr_req : std_ulogic;
    signal dbg_gpr_ack : std_ulogic;
    signal dbg_gpr_addr : gspr_index_t;
    signal dbg_gpr_data : std_ulogic_vector(63 downto 0);

    signal msr : std_ulogic_vector(63 downto 0);

    -- Debug status
    signal dbg_core_is_stopped: std_ulogic;

    -- Logging signals
    signal log_data    : std_ulogic_vector(255 downto 0);
    signal log_rd_addr : std_ulogic_vector(31 downto 0);
    signal log_wr_addr : std_ulogic_vector(31 downto 0);
    signal log_rd_data : std_ulogic_vector(63 downto 0);

    function keep_h(disable : boolean) return string is
    begin
	if disable then
	    return "yes";
	else
	    return "no";
	end if;
    end function;
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of fetch1_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of icache_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of decode1_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of decode2_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of register_file_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of cr_file_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of execute1_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of loadstore1_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of mmu_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of dcache_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of writeback_0 : label is keep_h(DISABLE_FLATTEN);
    attribute keep_hierarchy of debug_0 : label is keep_h(DISABLE_FLATTEN);
begin

    core_rst <= dbg_core_rst or rst;

    resets: process(clk)
    begin
        if rising_edge(clk) then
            rst_fetch1  <= core_rst;
            rst_fetch2  <= core_rst;
            rst_icache  <= core_rst;
            rst_dcache  <= core_rst;
            rst_dec1    <= core_rst;
            rst_dec2    <= core_rst;
            rst_ex1     <= core_rst;
            rst_ls1     <= core_rst;
            rst_dbg     <= rst;
            alt_reset_d <= alt_reset;
        end if;
    end process;

    fetch1_0: entity work.fetch1
        generic map (
            RESET_ADDRESS => (others => '0'),
	    ALT_RESET_ADDRESS => ALT_RESET_ADDRESS
            )
        port map (
            clk => clk,
            rst => rst_fetch1,
	    alt_reset_in => alt_reset_d,
            stall_in => fetch1_stall_in,
            flush_in => fetch1_flush,
	    stop_in => dbg_core_stop,
            d_in => decode1_to_fetch1,
            e_in => execute1_to_fetch1,
            i_out => fetch1_to_icache,
            log_out => log_data(42 downto 0)
            );

    fetch1_stall_in <= icache_stall_out or decode1_busy;
    fetch1_flush <= flush or decode1_flush;

    icache_0: entity work.icache
        generic map(
            SIM => SIM,
            LINE_SIZE => 64,
            NUM_LINES => 64,
	    NUM_WAYS => 2,
            LOG_LENGTH => LOG_LENGTH
            )
        port map(
            clk => clk,
            rst => rst_icache,
            i_in => fetch1_to_icache,
            i_out => icache_to_decode1,
            m_in => mmu_to_icache,
            flush_in => fetch1_flush,
            inval_in => dbg_icache_rst or ex1_icache_inval,
            stall_in => icache_stall_in,
	    stall_out => icache_stall_out,
            wishbone_out => wishbone_insn_out,
            wishbone_in => wishbone_insn_in,
            log_out => log_data(96 downto 43)
            );

    icache_stall_in <= decode1_busy;

    decode1_0: entity work.decode1
        generic map(
            LOG_LENGTH => LOG_LENGTH
            )
        port map (
            clk => clk,
            rst => rst_dec1,
            stall_in => decode1_stall_in,
            flush_in => flush,
            flush_out => decode1_flush,
            busy_out => decode1_busy,
            f_in => icache_to_decode1,
            d_out => decode1_to_decode2,
            f_out => decode1_to_fetch1,
            log_out => log_data(109 downto 97)
            );

    decode1_stall_in <= decode2_stall_out;

    decode2_0: entity work.decode2
        generic map (
            EX1_BYPASS => EX1_BYPASS,
            LOG_LENGTH => LOG_LENGTH
            )
        port map (
            clk => clk,
            rst => rst_dec2,
	    busy_in => decode2_busy_in,
            stall_out => decode2_stall_out,
            flush_in => flush,
            complete_in => complete,
	    stopped_out => dbg_core_is_stopped,
            d_in => decode1_to_decode2,
            e_out => decode2_to_execute1,
            r_in => register_file_to_decode2,
            r_out => decode2_to_register_file,
            c_in => cr_file_to_decode2,
            c_out => decode2_to_cr_file,
            log_out => log_data(119 downto 110)
            );
    decode2_busy_in <= ex1_busy_out;

    register_file_0: entity work.register_file
        generic map (
            SIM => SIM,
            LOG_LENGTH => LOG_LENGTH
            )
        port map (
            clk => clk,
            d_in => decode2_to_register_file,
            d_out => register_file_to_decode2,
            w_in => writeback_to_register_file,
            dbg_gpr_req => dbg_gpr_req,
            dbg_gpr_ack => dbg_gpr_ack,
            dbg_gpr_addr => dbg_gpr_addr,
            dbg_gpr_data => dbg_gpr_data,
	    sim_dump => terminate,
	    sim_dump_done => sim_cr_dump,
            log_out => log_data(255 downto 185)
	    );

    cr_file_0: entity work.cr_file
        generic map (
            SIM => SIM,
            LOG_LENGTH => LOG_LENGTH
            )
        port map (
            clk => clk,
            d_in => decode2_to_cr_file,
            d_out => cr_file_to_decode2,
            w_in => writeback_to_cr_file,
            sim_dump => sim_cr_dump,
            log_out => log_data(184 downto 172)
            );

    execute1_0: entity work.execute1
        generic map (
            EX1_BYPASS => EX1_BYPASS,
            LOG_LENGTH => LOG_LENGTH
            )
        port map (
            clk => clk,
            rst => rst_ex1,
            flush_out => flush,
	    busy_out => ex1_busy_out,
            e_in => decode2_to_execute1,
            l_in => loadstore1_to_execute1,
            ext_irq_in => ext_irq,
            l_out => execute1_to_loadstore1,
            f_out => execute1_to_fetch1,
            e_out => execute1_to_writeback,
	    icache_inval => ex1_icache_inval,
            dbg_msr_out => msr,
            terminate_out => terminate,
            log_out => log_data(134 downto 120),
            log_rd_addr => log_rd_addr,
            log_rd_data => log_rd_data,
            log_wr_addr => log_wr_addr
            );

    loadstore1_0: entity work.loadstore1
        generic map (
            LOG_LENGTH => LOG_LENGTH
            )
        port map (
            clk => clk,
            rst => rst_ls1,
            l_in => execute1_to_loadstore1,
            e_out => loadstore1_to_execute1,
            l_out => loadstore1_to_writeback,
            d_out => loadstore1_to_dcache,
            d_in => dcache_to_loadstore1,
            m_out => loadstore1_to_mmu,
            m_in => mmu_to_loadstore1,
            dc_stall => dcache_stall_out,
            log_out => log_data(149 downto 140)
            );

    mmu_0: entity work.mmu
        port map (
            clk => clk,
            rst => core_rst,
            l_in => loadstore1_to_mmu,
            l_out => mmu_to_loadstore1,
            d_out => mmu_to_dcache,
            d_in => dcache_to_mmu,
            i_out => mmu_to_icache
            );

    dcache_0: entity work.dcache
        generic map(
            LINE_SIZE => 64,
            NUM_LINES => 64,
	    NUM_WAYS => 2,
            LOG_LENGTH => LOG_LENGTH
            )
        port map (
            clk => clk,
	    rst => rst_dcache,
            d_in => loadstore1_to_dcache,
            d_out => dcache_to_loadstore1,
            m_in => mmu_to_dcache,
            m_out => dcache_to_mmu,
            stall_out => dcache_stall_out,
            wishbone_in => wishbone_data_in,
            wishbone_out => wishbone_data_out,
            log_out => log_data(171 downto 152)
            );

    writeback_0: entity work.writeback
        port map (
            clk => clk,
            e_in => execute1_to_writeback,
            l_in => loadstore1_to_writeback,
            w_out => writeback_to_register_file,
            c_out => writeback_to_cr_file,
            complete_out => complete
            );

    log_data(151 downto 150) <= "00";
    log_data(139 downto 135) <= "00000";

    debug_0: entity work.core_debug
        generic map (
            LOG_LENGTH => LOG_LENGTH
            )
	port map (
	    clk => clk,
	    rst => rst_dbg,
	    dmi_addr => dmi_addr,
	    dmi_din => dmi_din,
	    dmi_dout => dmi_dout,
	    dmi_req => dmi_req,
	    dmi_wr => dmi_wr,
	    dmi_ack => dmi_ack,
	    core_stop => dbg_core_stop,
	    core_rst => dbg_core_rst,
	    icache_rst => dbg_icache_rst,
	    terminate => terminate,
	    core_stopped => dbg_core_is_stopped,
	    nia => fetch1_to_icache.nia,
            msr => msr,
            dbg_gpr_req => dbg_gpr_req,
            dbg_gpr_ack => dbg_gpr_ack,
            dbg_gpr_addr => dbg_gpr_addr,
            dbg_gpr_data => dbg_gpr_data,
            log_data => log_data,
            log_read_addr => log_rd_addr,
            log_read_data => log_rd_data,
            log_write_addr => log_wr_addr,
	    terminated_out => terminated_out
	    );

end behave;
