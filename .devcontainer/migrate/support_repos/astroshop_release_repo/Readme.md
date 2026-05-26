# Manual release pipeline

This repo contains a manual release pipeline for Astroshop.

- Deployment 0 - Everything working (version 1.12.0) (Default)
- Deployment 1 - CPU issue (version 1.12.1)
- Deployment 2 - Memory issue (version 1.12.2)
- Deployment 3 - N+1 issue (version 1.12.3)


To deploy another version, trigger the pipeline with the value for VERSION=1.12.x where x is the deployment value.