# Some computed thermal conductivity results

* In each folder, there are three files:

| file            | description                                   |
|---------------- |-----------------------------------------------|
| create_xyz_in.m | create the xyz.in file for the simulation  |
| run.in          | the run.in file for the simulation   |
| kappa.txt       | the final results I obtained    |

* In kappa.txt
  * the first column gives the temperature
  * the second column gives the average thermal conductivity
  * the third column gives the statistical error (standard error)

* number of independent simulations:

| folder            | number of independent simulations |  method    |
|----------------   |------------|----------------------|
| diamond           | 50         | EMD                  |
| germanium         | 50         | EMD                  |

