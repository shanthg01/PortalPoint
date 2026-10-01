"""maybe_promote() against a throwaway local MLflow store (sqlite + local artifacts).

Pure-unit: no DB/S3. Regression coverage for MLflow 3's register_model rejecting
plain logged artifact files ("Unable to find a logged_model with artifact_path"),
which broke run_team_rating_projection.py's champion registration.
"""
import pickle

import mlflow
import pytest
from mlflow import MlflowClient

from portalpoint.modeling.mlflow_helpers import maybe_promote


@pytest.fixture
def client(tmp_path, monkeypatch):
    uri = f"sqlite:///{(tmp_path / 'mlruns.db').as_posix()}"
    mlflow.set_tracking_uri(uri)
    mlflow.set_registry_uri(uri)
    exp_id = mlflow.create_experiment("t", artifact_location=(tmp_path / "artifacts").as_uri())
    mlflow.set_experiment(experiment_id=exp_id)
    yield MlflowClient(tracking_uri=uri, registry_uri=uri)
    mlflow.set_tracking_uri(None)


def _run_with_plain_artifacts(tmp_path, metric_value: float) -> str:
    """Log raw .pkl files under team_rating_models/ (no mlflow model flavor)."""
    pkl = tmp_path / "off_model.pkl"
    pkl.write_bytes(pickle.dumps({"model": "m", "scaler": "s"}))
    with mlflow.start_run() as run:
        mlflow.log_artifact(str(pkl), artifact_path="team_rating_models")
        mlflow.log_metric("em_rmse", metric_value)
        return run.info.run_id


def test_first_version_of_plain_artifacts_becomes_champion(client, tmp_path):
    run_id = _run_with_plain_artifacts(tmp_path, 1.8)
    result = maybe_promote(client, "scorer", run_id, "team_rating_models", "em_rmse", 1.8,
                           higher_is_better=False)

    assert result.promoted
    champ = client.get_model_version_by_alias("scorer", "champion")
    assert champ.run_id == run_id
    assert champ.source.endswith("/team_rating_models")
    # The loader's actual access path: download an artifact by run_id + path.
    local = mlflow.artifacts.download_artifacts(run_id=run_id,
                                                artifact_path="team_rating_models/off_model.pkl")
    assert pickle.load(open(local, "rb"))["model"] == "m"


def test_second_plain_artifact_version_follows_gate(client, tmp_path):
    first = _run_with_plain_artifacts(tmp_path, 2.0)
    maybe_promote(client, "scorer", first, "team_rating_models", "em_rmse", 2.0, higher_is_better=False)

    worse = _run_with_plain_artifacts(tmp_path, 2.05)  # not >5% better -> stays put
    result = maybe_promote(client, "scorer", worse, "team_rating_models", "em_rmse", 2.05,
                           higher_is_better=False)

    assert not result.promoted
    assert client.get_model_version_by_alias("scorer", "champion").run_id == first
    assert len(client.search_model_versions("name='scorer'")) == 2
