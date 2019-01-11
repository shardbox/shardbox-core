require "spec"
require "../../src/service/import_catalog"
require "../support/jobs"
require "../support/db"
require "file_utils"

private def with_tempdir(name)
  path = File.join(Dir.tempdir, name)
  FileUtils.mkdir_p(path)

  begin
    yield path
  ensure
    FileUtils.rm_r(path) if File.exists?(path)
  end
end

describe Service::ImportCatalog do
  it "imports shards" do
    with_tempdir("import_catalog") do |path|
      catalog_path = File.join(path, "catalog")
      FileUtils.mkdir_p(catalog_path)
      File.write(File.join(catalog_path, "bar.yml"), <<-YAML)
        name: Bar
        shards:
        - github: foo/foo
        - git: https://example.com/foo/foo.git
        YAML
      File.write(File.join(catalog_path, "foo.yml"), <<-YAML)
        name: Foo
        shards:
        - github: foo/foo
        - git: https://example.com/foo/bar.git
        YAML

      transaction do |db|
        Service::ImportCatalog.new(catalog_path).import_catalog(db)
      end

      enqueued_jobs.should eq [
        {"Service::ImportShard", %({"repo_ref":{"resolver":"github","url":"foo/foo"}})},
        {"Service::ImportShard", %({"repo_ref":{"resolver":"git","url":"https://example.com/foo/bar.git"}})},
        {"Service::ImportShard", %({"repo_ref":{"resolver":"git","url":"https://example.com/foo/foo.git"}})},
      ]
    end
  end
end
