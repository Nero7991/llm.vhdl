-- sim/tb_embed_gather.vhd -- gate row: embed_gather at the 9B geometry (K 4096), plan Task 3.
entity tb_embed_gather is
end entity;
architecture sim of tb_embed_gather is
begin
  tc : entity work.embed_gather_tc
    generic map(N_EMBD => 4096, VEC => "embed_gather_k4096_vec.txt", TB_NAME => "tb_embed_gather");
end architecture;
