alias ControlPlane.{Repo, Fleet, Enrollment}
region = case Repo.get_by(Fleet.Region, code: "nl-1") do
  nil -> Repo.insert!(%Fleet.Region{code: "nl-1", name: "Nederland 1"}); r -> r end
{:ok, {tok, _}} = Enrollment.create_enroll_token(%{region_id: region.id, tier: :community, ttl_seconds: 3600})
File.write!("/work/enroll_token.txt", tok)
File.write!("/work/region_id.txt", region.id)
IO.puts("SEEDED")
