-- Segurança do Trabalho: a lista de pessoas da APR/PT/PET (app_seg_pessoas) passa a devolver o e-mail,
-- para o campo achar a pessoa também pelo e-mail (o datalist mostra "cargo · e-mail" e o Chrome busca no rótulo).
-- Só acrescenta a chave `email` no jsonb: mesma assinatura, compatível com o app anterior (v322), que ignora a chave.
create or replace function public.app_seg_pessoas()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'nome',coalesce(p.nome,p.email),'matricula',p.matricula,
      'cargo',coalesce(c.nome,p.cargo),'area',p.area,'consorcio',p.consorcio,'email',p.email) order by coalesce(p.nome,p.email))
    from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id=p.cargo_id
    where coalesce(p.ativo,true)),'[]'::jsonb);
end $function$;
