# SkyBlue IT Limited — CI/CD GitLab + Kubernetes + Helm

Solution de référence de l'examen. Application **FastAPI** (dépôt
`DataScientest/gitlab-app-fastapi`), construite en image Docker, publiée sur
**DockerHub**, déployée par **Helm** sur un cluster **Kubernetes** à 4
environnements (namespaces) : `dev`, `qa`, `staging`, `prod`.

> ✅ Cette solution n'est pas seulement écrite : elle a été **exécutée
> réellement** sur un cluster Kubernetes local (kind). L'image a été
> construite, les tests lancés, et l'app déployée + testée (HTTP 200) dans les
> 4 environnements. Les preuves sont dans `PREUVES_EXECUTION.txt` /
> `PREUVES_EXECUTION.pdf`.

## Arborescence des livrables

```
skyblue-devops/
├── .gitlab-ci.yml            # pipeline complet (test→build→run→push→deploy x4)
├── Dockerfile                # image FastAPI (python:3.9, /code, uvicorn:80)
├── requirements.txt          # deps de l'app
├── docker-compose.yml        # source de la conversion vers K8s/Helm
├── app/                      # code applicatif réel (main.py, test_main.py, ...)
├── k8s/
│   ├── namespaces.yaml       # les 4 environnements (dev/qa/staging/prod)
│   ├── deployment.yaml       # manifeste "brut" issu de docker-compose
│   └── service.yaml          # service NodePort "brut"
├── fastapi/                  # chart Helm (helm create fastapi, personnalisé)
│   ├── Chart.yaml
│   ├── values.yaml           # valeurs par défaut
│   ├── values-dev.yaml       # nodePort 30000, 1 réplica
│   ├── values-qa.yaml        # nodePort 30001, 1 réplica
│   ├── values-staging.yaml   # nodePort 30002, 2 réplicas
│   ├── values-prod.yaml      # nodePort 30003, 2 réplicas + resources
│   └── templates/
├── PREUVES_EXECUTION.txt     # sortie réelle du déploiement local
└── verify-local.sh           # rejoue toute la vérification de bout en bout
```

## Conversion docker-compose → Kubernetes → Helm

| docker-compose            | Kubernetes (k8s/)             | Helm (fastapi/)                         |
|---------------------------|-------------------------------|-----------------------------------------|
| `services: fastapi`       | `Deployment`                  | `templates/deployment.yaml`             |
| `build:` / `image:`       | `spec.containers[].image`     | `--set image.repository/.tag`           |
| `ports: "80:80"`          | `Service` type `NodePort`     | `templates/service.yaml` + `nodeport`   |
| (un par environnement)    | 1 `Namespace` par env         | `values-<env>.yaml`                     |

## Le pipeline (.gitlab-ci.yml)

Étapes : `test → build → run → push → deploy_dev → deploy_qa → deploy_staging → deploy_prod`.

- **test** : `pytest` (voir le point ⚠️ ci-dessous).
- **build** : `docker build`, image taguée `:$CI_COMMIT_SHORT_SHA`.
- **run** : démarre le conteneur et vérifie un HTTP 200 (test fumée).
- **push** : `docker login` DockerHub + `docker push` ; `:latest` poussé seulement sur `main`.
- **deploy_dev / qa / staging** : automatiques, `helm upgrade --install` dans le namespace.
- **deploy_prod** : **manuel ET uniquement sur `main`** :
  ```yaml
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual
    - when: never
  ```

## ⚠️ Deux corrections réelles par rapport au TP (vérifiées en exécutant)

1. **`pytest` doit tourner depuis la RACINE, pas depuis `app/`.**
   Le test fait `from .main import app` (import relatif), donc `app` doit rester
   un package. La commande du TP `cd app/ && pytest` **échoue** (« attempted
   relative import » / collection error). La bonne commande est `python -m pytest app/`.

2. **Il faut épingler `httpx<0.28`.**
   `requirements.txt` ne fige pas `httpx`. En 2026, `pip` installe `httpx 0.28`
   qui a **supprimé le paramètre `app=`** utilisé par le `TestClient` de
   Starlette 0.22 → le test plante avec
   `TypeError: __init__() got an unexpected keyword argument 'app'`.
   Le job `test` installe donc `pytest "httpx<0.28"`. (Idéalement, ajouter
   `httpx<0.28` au `requirements.txt` du dépôt.)

## Procédure complète sur un vrai serveur/cluster cloud

### 1. Installer Kubernetes et créer les 4 environnements
```bash
kubectl apply -f k8s/namespaces.yaml
kubectl get ns          # dev, qa, staging, prod
```

### 2. Compte DockerHub + secret `regcred` dans CHAQUE namespace
```bash
docker login -u <DOCKERHUB_USER>
for ns in dev qa staging prod; do
  kubectl create secret generic regcred \
    --from-file=.dockerconfigjson=$HOME/.docker/config.json \
    --type=kubernetes.io/dockerconfigjson -n $ns
done
kubectl get secret regcred -n dev      # vérification
```

### 3. Projet GitLab (cloud) + variables CI/CD
**Settings > CI/CD > Variables** :

| Clé              | Type     | Valeur                                | Protected |
|------------------|----------|---------------------------------------|-----------|
| `DOCKERHUB_USER` | Variable | identifiant DockerHub                 | non       |
| `DOCKERHUB_TOKEN`| Variable | *Access Token* DockerHub (masqué)     | non       |
| `KUBE_CONFIG`    | **File** | contenu de `~/.kube/config`           | non       |

> `mkdir -p ~/.kube && kubectl config view --raw > ~/.kube/config && chmod 700 ~/.kube/config`

### 4. Récupérer le projet, pousser sur GitLab
```bash
git clone https://github.com/DataScientest/gitlab-app-fastapi.git
# copier .gitlab-ci.yml, k8s/, fastapi/ à la racine du projet
git add . && git commit -m "CI/CD + manifests K8s + chart Helm" && git push origin main
```

### 5. Pipeline
`test → build → run → push → deploy_dev → deploy_qa → deploy_staging` automatiques ;
`deploy_prod` en manuel (bouton ▶), présent uniquement sur `main`.

## Réponses aux questions du cours
- **Créer un chart Helm** : `helm create fastapi`
- **Vérifier le secret dans dev** : `kubectl get secret regcred -n dev`

## Différences avec le TP du cours (adaptations exigées par l'examen)

| Point             | TP du cours                 | Cette solution (énoncé examen)            |
|-------------------|-----------------------------|-------------------------------------------|
| Environnements    | 3 (dev, staging, prod)      | **4** (dev, qa, staging, prod)            |
| Registre d'images | Registre privé **GitLab**   | **DockerHub** (`docker login`, token)     |
| Restriction prod  | `when: manual`              | `when: manual` **+ `rules` branche `main`**|
| Valeurs Helm      | `--set` épars               | `values-<env>.yaml` par environnement     |
| NodePorts         | 30000/30001/30002           | 30000/30001/30002/**30003**               |
| Test pytest       | `cd app/ && pytest` (KO)    | `python -m pytest app/` + `httpx<0.28`    |

## Reproduire la vérification locale (cluster kind)
```bash
./verify-local.sh      # build, tests, kind, 4 namespaces, helm x4, curl 200 x4
```

## Livrables à rendre (zip `nom_prenom_promo_annee`)
1. `lien_github.txt` — URL du dépôt GitHub (public)
2. `lien_dockerhub.txt` — URL du dépôt DockerHub (images publiées)
3. `captures_gitlab_ci.pdf` — captures des pipelines/jobs/environnements
   (ici remplacé/complété par `PREUVES_EXECUTION.pdf`, preuves d'exécution réelle)

> ⚠️ Le dépôt GitHub/GitLab doit être **public** pour la correction.
