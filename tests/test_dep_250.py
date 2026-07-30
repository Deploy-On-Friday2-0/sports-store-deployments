import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CHART_DIR = REPO_ROOT / "helm" / "sports-store"
IMAGE_DIR = REPO_ROOT / "environments" / "production" / "images"
APPLICATION = REPO_ROOT / "apps" / "sports-store-production.yaml"
YQ = os.environ.get("YQ_BIN", "yq")
HELM = os.environ.get("HELM_BIN", "helm")

SERVICES = {
    "auth-service": ("auth", "sports-store-auth-service"),
    "cart-service": ("cart", "sports-store-cart-service"),
    "catalog-service": ("catalog", "sports-store-catalog-service"),
    "order-service": ("order", "sports-store-order-service"),
    "payment-service": ("payment", "sports-store-payment-service"),
    "gateway": ("gateway", "sports-store-gateway"),
}
TAG_PATTERN = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")


def run(command, *, env=None, check=True):
    return subprocess.run(
        [str(part) for part in command],
        cwd=REPO_ROOT,
        env=env,
        check=check,
        capture_output=True,
        text=True,
    )


def yq(expression, path):
    return run([YQ, expression, path]).stdout.strip()


def overlay_paths(base=IMAGE_DIR):
    return [base / f"{service}.yaml" for service in SERVICES]


def render(overlays=None, *, check=True):
    overlays = overlays or overlay_paths()
    command = [
        HELM,
        "template",
        "sports-store",
        CHART_DIR,
        "--namespace",
        "sports-store",
        "--show-only",
        "templates/deployment.yaml",
        "-f",
        CHART_DIR / "values-eks.yaml",
    ]
    for values_file in overlays:
        command.extend(["-f", values_file])
    return run(command, check=check)


def rendered_image(rendered, workload):
    documents = re.split(r"^---\s*$", rendered, flags=re.MULTILINE)
    for document in documents:
        if re.search(rf"^  name: {re.escape(workload)}$", document, re.MULTILINE):
            match = re.search(r'^\s+image: "?([^"\s]+)"?$', document, re.MULTILINE)
            if match:
                return match.group(1)
    raise AssertionError(f"Rendered Deployment {workload!r} was not found")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ProductionImageContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for executable in (YQ, HELM):
            if not Path(executable).exists() and shutil.which(executable) is None:
                raise unittest.SkipTest(f"Required executable is unavailable: {executable}")

    def test_all_required_manifests_have_valid_source_and_helm_tags(self):
        self.assertEqual(
            {path.stem for path in IMAGE_DIR.glob("*.yaml")}, set(SERVICES)
        )
        for service, (workload, _) in SERVICES.items():
            manifest = IMAGE_DIR / f"{service}.yaml"
            source_tag = yq(".image.tag", manifest)
            consumed_tag = yq(f"explode(.) | .services.{workload}.tag", manifest)
            self.assertRegex(source_tag, TAG_PATTERN)
            self.assertEqual(source_tag, consumed_tag)

    def test_argocd_application_consumes_every_manifest_once(self):
        value_files = yq(".spec.source.helm.valueFiles[]", APPLICATION).splitlines()
        expected = [
            f"../../environments/production/images/{service}.yaml"
            for service in SERVICES
        ]
        self.assertEqual(value_files[0], "values-eks.yaml")
        self.assertCountEqual(value_files[1:], expected)
        self.assertEqual(len(value_files[1:]), len(set(value_files[1:])))

    def test_each_manifest_tag_is_used_by_its_rendered_workload(self):
        rendered = render().stdout
        for service, (workload, repository) in SERVICES.items():
            tag = yq(".image.tag", IMAGE_DIR / f"{service}.yaml")
            self.assertEqual(rendered_image(rendered, workload), f"{repository}:{tag}")

    def test_missing_and_invalid_tags_fail_helm_rendering(self):
        for tag in ("", "invalid/tag"):
            with self.subTest(tag=tag), tempfile.TemporaryDirectory() as temp_dir:
                temp_root = Path(temp_dir)
                for source in overlay_paths():
                    shutil.copy2(source, temp_root / source.name)
                auth_file = temp_root / "auth-service.yaml"
                env = os.environ.copy()
                env["IMAGE_TAG"] = tag
                run(
                    [YQ, "-i", ".image.tag = strenv(IMAGE_TAG)", auth_file], env=env
                )
                result = render(overlay_paths(temp_root), check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(
                    result.stderr + result.stdout,
                    r"services\.auth\.tag (must be set|is not a valid container image tag)",
                )

    def test_yq_writeback_changes_only_target_render_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            for source in overlay_paths():
                shutil.copy2(source, temp_root / source.name)
            overlays = overlay_paths(temp_root)
            before_hashes = {path.name: digest(path) for path in overlays}
            before_render = render(overlays).stdout

            desired_tag = "1.0.0-deadbee"
            env = os.environ.copy()
            env["IMAGE_TAG"] = desired_tag
            auth_file = temp_root / "auth-service.yaml"
            run([YQ, "-i", ".image.tag = strenv(IMAGE_TAG)", auth_file], env=env)

            after_hashes = {path.name: digest(path) for path in overlays}
            changed = {
                name for name in before_hashes if before_hashes[name] != after_hashes[name]
            }
            self.assertEqual(changed, {"auth-service.yaml"})
            self.assertNotEqual(
                rendered_image(before_render, "auth"),
                rendered_image(render(overlays).stdout, "auth"),
            )
            self.assertEqual(
                rendered_image(render(overlays).stdout, "auth"),
                f"sports-store-auth-service:{desired_tag}",
            )

            first_update_hash = digest(auth_file)
            run([YQ, "-i", ".image.tag = strenv(IMAGE_TAG)", auth_file], env=env)
            self.assertEqual(digest(auth_file), first_update_hash)

    def test_application_workflows_target_the_exact_manifests(self):
        app_root = Path(
            os.environ.get("APPLICATION_REPOS_ROOT", str(REPO_ROOT.parent))
        )
        missing_repositories = [
            repository
            for _, repository in SERVICES.values()
            if not (app_root / repository).is_dir()
        ]
        if missing_repositories:
            self.skipTest(
                "Application repositories are not available in this checkout: "
                + ", ".join(missing_repositories)
            )
        for service, (_, application_repo) in SERVICES.items():
            workflow = app_root / application_repo / ".github" / "workflows" / "publish.yml"
            self.assertTrue(workflow.is_file(), f"Missing application workflow: {workflow}")
            content = workflow.read_text(encoding="utf-8")
            expected = f"environments/production/images/{service}.yaml"
            self.assertEqual(
                content.count(expected),
                2,
                f"{application_repo} must use {expected} in yq and IMAGE_FILE only",
            )


if __name__ == "__main__":
    unittest.main()
