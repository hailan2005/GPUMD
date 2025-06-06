/*
    Copyright 2017 Zheyong Fan and GPUMD development team
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/

/*----------------------------------------------------------------------------80
The class dealing with the interlayer potential(ILP) and Tersoff.
TODO:
------------------------------------------------------------------------------*/

#include "ilp_tersoff.cuh"
#include "neighbor.cuh"
#include "utilities/error.cuh"
#include "utilities/common.cuh"
#include "utilities/gpu_macro.cuh"
#include <cstring>

#define BLOCK_SIZE_FORCE 128

// there are most 3 intra-layer neighbors for gr and hbn
#define NNEI 3


#define LDG(a, n) __ldg(a + n)
#define EPSILON 1.0e-15

// Easy labels for indexing
#define A 0
#define B 1
#define LAMBDA 2
#define MU 3
#define BETA 4
#define EN 5 // special name for n to avoid conflict
#define C 6
#define D 7
#define H 8
#define R1 9
#define R2 10
#define M 11
#define ALPHA 12
#define GAMMA 13
#define C2 14
#define D2 15
#define ONE_PLUS_C2OVERD2 16
#define PI_FACTOR 17
#define MINUS_HALF_OVER_N 18

#define NUM_PARAMS 19


ILP_TERSOFF::ILP_TERSOFF(FILE* fid_ilp, FILE* fid_tersoff, int num_types, int num_atoms)
{
  // read ILP Tersoff potential parameter
  printf("Use %d-element ILP potential with elements:\n", num_types);
  ILP_TERSOFF::num_types = num_types;
  if (!(num_types >= 1 && num_types <= MAX_TYPE_ILP_TERSOFF)) {
    PRINT_INPUT_ERROR("Incorrect type number of ILP_TERSOFF parameters.\n");
  }
  for (int n = 0; n < num_types; ++n) {
    char atom_symbol[10];
    int count = fscanf(fid_ilp, "%s", atom_symbol);
    PRINT_SCANF_ERROR(count, 1, "Reading error for ILP_TERSOFF potential.");
    printf(" %s", atom_symbol);
  }
  printf("\n");

  // read ILP group method
  PRINT_SCANF_ERROR(fscanf(fid_ilp, "%d", &ilp_group_method), 1, 
  "Reading error for ILP group method.");
  printf("Use group method %d to identify molecule for ILP.\n", ilp_group_method);

  // read parameters
  float beta, alpha, delta, epsilon, CC, d, sR;
  float reff, C6, S, rcut_ilp, rcut_global;
  rc = 0.0;
  for (int n = 0; n < num_types; ++n) {
    for (int m = 0; m < num_types; ++m) {
      int count = fscanf(fid_ilp, "%f%f%f%f%f%f%f%f%f%f%f%f", \
      &beta, &alpha, &delta, &epsilon, &CC, &d, &sR, &reff, &C6, &S, \
      &rcut_ilp, &rcut_global);
      PRINT_SCANF_ERROR(count, 12, "Reading error for ILP_TERSOFF potential.");

      ilp_para.CC[n][m] = CC;
      ilp_para.C_6[n][m] = C6;
      ilp_para.d[n][m] = d;
      ilp_para.d_Seff[n][m] = d / sR / reff;
      ilp_para.epsilon[n][m] = epsilon;
      ilp_para.z0[n][m] = beta;
      ilp_para.lambda[n][m] = alpha / beta;
      ilp_para.delta2inv[n][m] = 1.0 / (delta * delta);
      ilp_para.S[n][m] = S;
      ilp_para.rcutsq_ilp[n][m] = rcut_ilp * rcut_ilp;
      ilp_para.rcut_global[n][m] = rcut_global;
      float meV = 1e-3 * S;
      ilp_para.CC[n][m] *= meV;
      ilp_para.C_6[n][m] *= meV;
      ilp_para.epsilon[n][m] *= meV;

      if (rc < rcut_global)
        rc = rcut_global;
    }
  }

  // read Tersoff potential parameter
  initialize_tersoff_1988(fid_tersoff, num_atoms);

  // initialize neighbor lists and some temp vectors
  int max_neighbor_number = min(num_atoms, CUDA_MAX_NL_CBN);
  ilp_data.NN.resize(num_atoms);
  ilp_data.NL.resize(num_atoms * max_neighbor_number);
  ilp_data.cell_count.resize(num_atoms);
  ilp_data.cell_count_sum.resize(num_atoms);
  ilp_data.cell_contents.resize(num_atoms);

  // init ilp neighbor list
  ilp_data.ilp_NN.resize(num_atoms);
  ilp_data.ilp_NL.resize(num_atoms * MAX_ILP_NEIGHBOR_CBN);
  ilp_data.reduce_NL.resize(num_atoms * max_neighbor_number);
  ilp_data.big_ilp_NN.resize(num_atoms);
  ilp_data.big_ilp_NL.resize(num_atoms * MAX_BIG_ILP_NEIGHBOR_CBN);

  ilp_data.f12x.resize(num_atoms * max_neighbor_number);
  ilp_data.f12y.resize(num_atoms * max_neighbor_number);
  ilp_data.f12z.resize(num_atoms * max_neighbor_number);

  ilp_data.f12x_ilp_neigh.resize(num_atoms * MAX_ILP_NEIGHBOR_CBN);
  ilp_data.f12y_ilp_neigh.resize(num_atoms * MAX_ILP_NEIGHBOR_CBN);
  ilp_data.f12z_ilp_neigh.resize(num_atoms * MAX_ILP_NEIGHBOR_CBN);

  // intialize tersoff neighbor list
  tersoff_data.NN.resize(num_atoms);
  tersoff_data.NL.resize(num_atoms * 1024); // the largest supported by CUDA
  tersoff_data.cell_count.resize(num_atoms);
  tersoff_data.cell_count_sum.resize(num_atoms);
  tersoff_data.cell_contents.resize(num_atoms);

  // memory for the partial forces dU_i/dr_ij
  const int num_of_neighbors = MAX_TERSOFF_NEIGHBOR_NUM * num_atoms;
  tersoff_data.f12x.resize(num_of_neighbors);
  tersoff_data.f12y.resize(num_of_neighbors);
  tersoff_data.f12z.resize(num_of_neighbors);

  // init constant cutoff coeff
  float h_tap_coeff[8] = \
    {1.0f, 0.0f, 0.0f, 0.0f, -35.0f, 84.0f, -70.0f, 20.0f};
  CHECK(gpuMemcpyToSymbol(Tap_coeff_CBN, h_tap_coeff, 8 * sizeof(float)));

  // set ilp_flag to 1
  ilp_flag = 1;
}

ILP_TERSOFF::~ILP_TERSOFF(void)
{
  // nothing
}

void ILP_TERSOFF::initialize_tersoff_1988(FILE* fid, int num_atoms)
{
  int n_entries = num_types * num_types * num_types;
  // 14 parameters per entry of tersoff1988 + 5 pre-calculated values
  std::vector<double> cpu_ters(n_entries * NUM_PARAMS);

  char err[50] = "Error: Illegal Tersoff parameter.";
  rc_tersoff = 0.0;
  int count = 0;
  double a, b, lambda, mu, beta, n, c, d, h, r1, r2, m, alpha, gamma;
  for (int i = 0; i < n_entries; i++) {
    count = fscanf(
      fid,
      "%lf%lf%lf%lf%lf%lf%lf%lf%lf%lf%lf%lf%lf%lf",
      &a,
      &b,
      &lambda,
      &mu,
      &beta,
      &n,
      &c,
      &d,
      &h,
      &r1,
      &r2,
      &m,
      &alpha,
      &gamma);
    if (count != 14) {
      printf("Error: reading error for potential.in.\n");
      exit(1);
    }

    int m_int = round(m);
    // Parameter checking
    if (a < 0.0) {
      printf("%s A must be >= 0.\n", err);
      exit(1);
    }
    if (b < 0.0) {
      printf("%s B must be >= 0.\n", err);
      exit(1);
    }
    if (lambda < 0.0) {
      printf("%s Lambda must be >= 0.\n", err);
      exit(1);
    }
    if (mu < 0.0) {
      printf("%s Mu must be >= 0.\n", err);
      exit(1);
    }
    if (beta < 0.0) {
      printf("%s Beta must be >= 0.\n", err);
      exit(1);
    }
    if (n < 0.0) {
      printf("%s n must be >= 0.\n", err);
      exit(1);
    }
    if (c < 0.0) {
      printf("%s c must be >= 0.\n", err);
      exit(1);
    }
    if (d < 0.0) {
      printf("%s d must be >= 0.\n", err);
      exit(1);
    }
    if (r1 < 0.0) {
      printf("%s R must be >= 0.\n", err);
      exit(1);
    }
    if (r2 < 0.0) {
      printf("%s S must be >= 0.\n", err);
      exit(1);
    }
    if (r2 < r1) {
      printf("%s S-R must be >= 0.\n", err);
      exit(1);
    }
    if (m_int != 3 && m_int != 1) {
      printf("%s m must be 1 or 3.\n", err);
      exit(1);
    }
    if (gamma < 0.0) {
      printf("%s Gamma must be >= 0.\n", err);
      exit(1);
    }

    cpu_ters[i * NUM_PARAMS + A] = a;
    cpu_ters[i * NUM_PARAMS + B] = b;
    cpu_ters[i * NUM_PARAMS + LAMBDA] = lambda;
    cpu_ters[i * NUM_PARAMS + MU] = mu;
    cpu_ters[i * NUM_PARAMS + BETA] = beta;
    cpu_ters[i * NUM_PARAMS + EN] = n;
    cpu_ters[i * NUM_PARAMS + C] = c;
    cpu_ters[i * NUM_PARAMS + D] = d;
    cpu_ters[i * NUM_PARAMS + H] = h;
    cpu_ters[i * NUM_PARAMS + R1] = r1;
    cpu_ters[i * NUM_PARAMS + R2] = r2;
    cpu_ters[i * NUM_PARAMS + M] = m_int;
    if (alpha < EPSILON) {
      cpu_ters[i * NUM_PARAMS + ALPHA] = 0.0;
    } else {
      cpu_ters[i * NUM_PARAMS + ALPHA] = alpha;
    }
    cpu_ters[i * NUM_PARAMS + GAMMA] = gamma;
    cpu_ters[i * NUM_PARAMS + C2] = c * c;
    cpu_ters[i * NUM_PARAMS + D2] = d * d;
    cpu_ters[i * NUM_PARAMS + ONE_PLUS_C2OVERD2] =
      1.0 + cpu_ters[i * NUM_PARAMS + C2] / cpu_ters[i * NUM_PARAMS + D2];
    cpu_ters[i * NUM_PARAMS + PI_FACTOR] = PI / (r2 - r1);
    cpu_ters[i * NUM_PARAMS + MINUS_HALF_OVER_N] = -0.5 / n;
    rc_tersoff = r2 > rc_tersoff ? r2 : rc_tersoff;
  }

  int num_of_neighbors = 50 * num_atoms;
  tersoff_data.b.resize(num_of_neighbors);
  tersoff_data.bp.resize(num_of_neighbors);
  tersoff_data.f12x.resize(num_of_neighbors);
  tersoff_data.f12y.resize(num_of_neighbors);
  tersoff_data.f12z.resize(num_of_neighbors);
  tersoff_data.NN.resize(num_atoms);
  tersoff_data.NL.resize(num_of_neighbors);
  tersoff_data.cell_count.resize(num_atoms);
  tersoff_data.cell_count_sum.resize(num_atoms);
  tersoff_data.cell_contents.resize(num_atoms);
  ters.resize(n_entries * NUM_PARAMS);
  ters.copy_from_host(cpu_ters.data());
}


static __device__ __forceinline__ float calc_Tap(const float r_ij, const float Rcutinv)
{
  float Tap, r;

  r = r_ij * Rcutinv;
  if (r >= 1.0f) {
    Tap = 0.0f;
  } else {
    Tap = Tap_coeff_CBN[7];
    for (int i = 6; i >= 0; --i) {
      Tap = Tap * r + Tap_coeff_CBN[i];
    }
  }

  return Tap;
}

// calculate the derivatives of long-range cutoff term
static __device__ __forceinline__ float calc_dTap(const float r_ij, const float Rcut, const float Rcutinv)
{
  float dTap, r;
  
  r = r_ij * Rcutinv;
  if (r >= Rcut) {
    dTap = 0.0f;
  } else {
    dTap = 7.0f * Tap_coeff_CBN[7];
    for (int i = 6; i > 0; --i) {
      dTap = dTap * r + i * Tap_coeff_CBN[i];
    }
    dTap *= Rcutinv;
  }

  return dTap;
}

// create ILP neighbor list from main neighbor list to calculate normals
static __global__ void ILP_neighbor(
  const int number_of_particles,
  const int N1,
  const int N2,
  const Box box,
  const int *g_neighbor_number,
  const int *g_neighbor_list,
  const int *g_type,
  ILP_CBN_Para ilp_para,
  const double* __restrict__ g_x,
  const double* __restrict__ g_y,
  const double* __restrict__ g_z,
  int *ilp_neighbor_number,
  int *ilp_neighbor_list,
  const int *group_label)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index

  if (n1 < N2) {
    int count = 0;
    int neighbor_number = g_neighbor_number[n1];
    int type1 = g_type[n1];
    double x1 = g_x[n1];
    double y1 = g_y[n1];
    double z1 = g_z[n1];

    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int n2 = g_neighbor_list[n1 + number_of_particles * i1];
      int type2 = g_type[n2];

      double x12 = g_x[n2] - x1;
      double y12 = g_y[n2] - y1;
      double z12 = g_z[n2] - z1;
      apply_mic(box, x12, y12, z12);
      double d12sq = x12 * x12 + y12 * y12 + z12 * z12;
      double rcutsq = ilp_para.rcutsq_ilp[type1][type2];


      if (group_label[n1] == group_label[n2] && d12sq < rcutsq && d12sq != 0) {
        ilp_neighbor_list[count++ * number_of_particles + n1] = n2;
      }
    }
    ilp_neighbor_number[n1] = count;

    if (count > MAX_ILP_NEIGHBOR_CBN) {
      // error, there are too many neighbors for some atoms, 
      printf("\n===== ILP neighbor number[%d] is greater than 3 =====\n", count);
      
      int nei1 = ilp_neighbor_list[0 * number_of_particles + n1];
      int nei2 = ilp_neighbor_list[1 * number_of_particles + n1];
      int nei3 = ilp_neighbor_list[2 * number_of_particles + n1];
      int nei4 = ilp_neighbor_list[3 * number_of_particles + n1];
      printf("===== n1[%d] nei1[%d] nei2 [%d] nei3[%d] nei4[%d] =====\n", n1, nei1, nei2, nei3, nei4);
      return;
      // please check your configuration
    }
  }
}


// calculate the normals and its derivatives
static __device__ void calc_normal(
  float (&vet)[3][3],
  int cont,
  float (&normal)[3],
  float (&dnormdri)[3][3],
  float (&dnormal)[3][3][3])
{
  int id, ip, m;
  float pv12[3], pv31[3], pv23[3], n1[3], dni[3];
  float dnn[3][3], dpvdri[3][3];
  float dn1[3][3][3], dpv12[3][3][3], dpv23[3][3][3], dpv31[3][3][3];

  float nninv, continv;

  // initialize the arrays
  for (id = 0; id < 3; id++) {
    pv12[id] = 0.0f;
    pv31[id] = 0.0f;
    pv23[id] = 0.0f;
    n1[id] = 0.0f;
    dni[id] = 0.0f;
    for (ip = 0; ip < 3; ip++) {
      dnn[ip][id] = 0.0f;
      dpvdri[ip][id] = 0.0f;
      for (m = 0; m < 3; m++) {
        dpv12[ip][id][m] = 0.0f;
        dpv31[ip][id][m] = 0.0f;
        dpv23[ip][id][m] = 0.0f;
        dn1[ip][id][m] = 0.0f;
      }
    }
  }

  if (cont <= 1) {
    normal[0] = 0.0;
    normal[1] = 0.0;
    normal[2] = 1.0;
    for (id = 0; id < 3; ++id) {
      for (ip = 0; ip < 3; ++ip) {
        dnormdri[id][ip] = 0.0;
        for (m = 0; m < 3; ++m) {
          dnormal[id][ip][m] = 0.0;
        }
      }
    }
  } else if (cont == 2) {
    pv12[0] = vet[0][1] * vet[1][2] - vet[1][1] * vet[0][2];
    pv12[1] = vet[0][2] * vet[1][0] - vet[1][2] * vet[0][0];
    pv12[2] = vet[0][0] * vet[1][1] - vet[1][0] * vet[0][1];
    // derivatives of pv12[0] to ri
    dpvdri[0][0] = 0.0f;
    dpvdri[0][1] = vet[0][2] - vet[1][2];
    dpvdri[0][2] = vet[1][1] - vet[0][1];
    // derivatives of pv12[1] to ri
    dpvdri[1][0] = vet[1][2] - vet[0][2];
    dpvdri[1][1] = 0.0f;
    dpvdri[1][2] = vet[0][0] - vet[1][0];
    // derivatives of pv12[2] to ri
    dpvdri[2][0] = vet[0][1] - vet[1][1];
    dpvdri[2][1] = vet[1][0] - vet[0][0];
    dpvdri[2][2] = 0.0f;

    dpv12[0][0][0] = 0.0f;
    dpv12[0][1][0] = vet[1][2];
    dpv12[0][2][0] = -vet[1][1];
    dpv12[1][0][0] = -vet[1][2];
    dpv12[1][1][0] = 0.0f;
    dpv12[1][2][0] = vet[1][0];
    dpv12[2][0][0] = vet[1][1];
    dpv12[2][1][0] = -vet[1][0];
    dpv12[2][2][0] = 0.0f;

    // derivatives respect to the second neighbor, atom l
    dpv12[0][0][1] = 0.0f;
    dpv12[0][1][1] = -vet[0][2];
    dpv12[0][2][1] = vet[0][1];
    dpv12[1][0][1] = vet[0][2];
    dpv12[1][1][1] = 0.0f;
    dpv12[1][2][1] = -vet[0][0];
    dpv12[2][0][1] = -vet[0][1];
    dpv12[2][1][1] = vet[0][0];
    dpv12[2][2][1] = 0.0f;

    // derivatives respect to the third neighbor, atom n
    // derivatives of pv12 to rn is zero
    for (id = 0; id < 3; id++) {
      for (ip = 0; ip < 3; ip++) { dpv12[id][ip][2] = 0.0f; }
    }

    n1[0] = pv12[0];
    n1[1] = pv12[1];
    n1[2] = pv12[2];
    // the magnitude of the normal vector
    nninv = rnorm3df(n1[0], n1[1], n1[2]);
    

    // the unit normal vector
    normal[0] = n1[0] * nninv;
    normal[1] = n1[1] * nninv;
    normal[2] = n1[2] * nninv;
    // derivatives of nn, dnn:3x1 vector
    dni[0] = (n1[0] * dpvdri[0][0] + n1[1] * dpvdri[1][0] + n1[2] * dpvdri[2][0]) * nninv;
    dni[1] = (n1[0] * dpvdri[0][1] + n1[1] * dpvdri[1][1] + n1[2] * dpvdri[2][1]) * nninv;
    dni[2] = (n1[0] * dpvdri[0][2] + n1[1] * dpvdri[1][2] + n1[2] * dpvdri[2][2]) * nninv;
    // derivatives of unit vector ni respect to ri, the result is 3x3 matrix
    for (id = 0; id < 3; id++) {
      for (ip = 0; ip < 3; ip++) {
        dnormdri[id][ip] = dpvdri[id][ip] * nninv - n1[id] * dni[ip] * nninv * nninv;
      }
    }
    // derivatives of non-normalized normal vector, dn1:3x3x3 array
    for (id = 0; id < 3; id++) {
      for (ip = 0; ip < 3; ip++) {
        for (m = 0; m < 3; m++) { dn1[id][ip][m] = dpv12[id][ip][m]; }
      }
    }
    // derivatives of nn, dnn:3x3 vector
    // dnn[id][m]: the derivative of nn respect to r[id][m], id,m=0,1,2
    // r[id][m]: the id's component of atom m
    for (m = 0; m < 3; m++) {
      for (id = 0; id < 3; id++) {
        dnn[id][m] = (n1[0] * dn1[0][id][m] + n1[1] * dn1[1][id][m] + n1[2] * dn1[2][id][m]) * nninv;
      }
    }
    // dnormal[id][ip][m][i]: the derivative of normal[id] respect to r[ip][m], id,ip=0,1,2
    // for atom m, which is a neighbor atom of atom i, m=0,jnum-1
    for (m = 0; m < 3; m++) {
      for (id = 0; id < 3; id++) {
        for (ip = 0; ip < 3; ip++) {
          dnormal[id][ip][m] = dn1[id][ip][m] * nninv - n1[id] * dnn[ip][m] * nninv * nninv;
        }
      }
    }
  } else if (cont == 3) {
    continv = 1.0 / cont;

    pv12[0] = vet[0][1] * vet[1][2] - vet[1][1] * vet[0][2];
    pv12[1] = vet[0][2] * vet[1][0] - vet[1][2] * vet[0][0];
    pv12[2] = vet[0][0] * vet[1][1] - vet[1][0] * vet[0][1];
    // derivatives respect to the first neighbor, atom k
    dpv12[0][0][0] = 0.0f;
    dpv12[0][1][0] = vet[1][2];
    dpv12[0][2][0] = -vet[1][1];
    dpv12[1][0][0] = -vet[1][2];
    dpv12[1][1][0] = 0.0f;
    dpv12[1][2][0] = vet[1][0];
    dpv12[2][0][0] = vet[1][1];
    dpv12[2][1][0] = -vet[1][0];
    dpv12[2][2][0] = 0.0f;
    // derivatives respect to the second neighbor, atom l
    dpv12[0][0][1] = 0.0f;
    dpv12[0][1][1] = -vet[0][2];
    dpv12[0][2][1] = vet[0][1];
    dpv12[1][0][1] = vet[0][2];
    dpv12[1][1][1] = 0.0f;
    dpv12[1][2][1] = -vet[0][0];
    dpv12[2][0][1] = -vet[0][1];
    dpv12[2][1][1] = vet[0][0];
    dpv12[2][2][1] = 0.0f;

    // derivatives respect to the third neighbor, atom n
    for (id = 0; id < 3; id++) {
      for (ip = 0; ip < 3; ip++) { dpv12[id][ip][2] = 0.0f; }
    }

    pv31[0] = vet[2][1] * vet[0][2] - vet[0][1] * vet[2][2];
    pv31[1] = vet[2][2] * vet[0][0] - vet[0][2] * vet[2][0];
    pv31[2] = vet[2][0] * vet[0][1] - vet[0][0] * vet[2][1];
    // derivatives respect to the first neighbor, atom k
    dpv31[0][0][0] = 0.0f;
    dpv31[0][1][0] = -vet[2][2];
    dpv31[0][2][0] = vet[2][1];
    dpv31[1][0][0] = vet[2][2];
    dpv31[1][1][0] = 0.0f;
    dpv31[1][2][0] = -vet[2][0];
    dpv31[2][0][0] = -vet[2][1];
    dpv31[2][1][0] = vet[2][0];
    dpv31[2][2][0] = 0.0f;
    // derivatives respect to the third neighbor, atom n
    dpv31[0][0][2] = 0.0f;
    dpv31[0][1][2] = vet[0][2];
    dpv31[0][2][2] = -vet[0][1];
    dpv31[1][0][2] = -vet[0][2];
    dpv31[1][1][2] = 0.0f;
    dpv31[1][2][2] = vet[0][0];
    dpv31[2][0][2] = vet[0][1];
    dpv31[2][1][2] = -vet[0][0];
    dpv31[2][2][2] = 0.0f;
    // derivatives respect to the second neighbor, atom l
    for (id = 0; id < 3; id++) {
      for (ip = 0; ip < 3; ip++) { dpv31[id][ip][1] = 0.0f; }
    }

    pv23[0] = vet[1][1] * vet[2][2] - vet[2][1] * vet[1][2];
    pv23[1] = vet[1][2] * vet[2][0] - vet[2][2] * vet[1][0];
    pv23[2] = vet[1][0] * vet[2][1] - vet[2][0] * vet[1][1];
    // derivatives respect to the second neighbor, atom k
    for (id = 0; id < 3; id++) {
      for (ip = 0; ip < 3; ip++) { dpv23[id][ip][0] = 0.0f; }
    }
    // derivatives respect to the second neighbor, atom l
    dpv23[0][0][1] = 0.0f;
    dpv23[0][1][1] = vet[2][2];
    dpv23[0][2][1] = -vet[2][1];
    dpv23[1][0][1] = -vet[2][2];
    dpv23[1][1][1] = 0.0f;
    dpv23[1][2][1] = vet[2][0];
    dpv23[2][0][1] = vet[2][1];
    dpv23[2][1][1] = -vet[2][0];
    dpv23[2][2][1] = 0.0f;
    // derivatives respect to the third neighbor, atom n
    dpv23[0][0][2] = 0.0f;
    dpv23[0][1][2] = -vet[1][2];
    dpv23[0][2][2] = vet[1][1];
    dpv23[1][0][2] = vet[1][2];
    dpv23[1][1][2] = 0.0f;
    dpv23[1][2][2] = -vet[1][0];
    dpv23[2][0][2] = -vet[1][1];
    dpv23[2][1][2] = vet[1][0];
    dpv23[2][2][2] = 0.0f;

    //############################################################################################
    // average the normal vectors by using the 3 neighboring planes
    n1[0] = (pv12[0] + pv31[0] + pv23[0]) * continv;
    n1[1] = (pv12[1] + pv31[1] + pv23[1]) * continv;
    n1[2] = (pv12[2] + pv31[2] + pv23[2]) * continv;

    nninv = rnorm3df(n1[0], n1[1], n1[2]);

    // the unit normal vector
    normal[0] = n1[0] * nninv;
    normal[1] = n1[1] * nninv;
    normal[2] = n1[2] * nninv;

    // for the central atoms, dnormdri is always zero
    for (id = 0; id < 3; id++) {
      for (ip = 0; ip < 3; ip++) { dnormdri[id][ip] = 0.0f; }
    }

    // derivatives of non-normalized normal vector, dn1:3x3x3 array
    for (id = 0; id < 3; id++) {
      for (ip = 0; ip < 3; ip++) {
        for (m = 0; m < 3; m++) {
          dn1[id][ip][m] = (dpv12[id][ip][m] + dpv23[id][ip][m] + dpv31[id][ip][m]) * continv;
        }
      }
    }
    // derivatives of nn, dnn:3x3 vector
    // dnn[id][m]: the derivative of nn respect to r[id][m], id,m=0,1,2
    // r[id][m]: the id's component of atom m
    for (m = 0; m < 3; m++) {
      for (id = 0; id < 3; id++) {
        dnn[id][m] = (n1[0] * dn1[0][id][m] + n1[1] * dn1[1][id][m] + n1[2] * dn1[2][id][m]) * nninv;
      }
    }
    // dnormal[id][ip][m][i]: the derivative of normal[id] respect to r[ip][m], id,ip=0,1,2
    // for atom m, which is a neighbor atom of atom i, m=0,jnum-1
    for (m = 0; m < 3; m++) {
      for (id = 0; id < 3; id++) {
        for (ip = 0; ip < 3; ip++) {
          dnormal[id][ip][m] = dn1[id][ip][m] * nninv - n1[id] * dnn[ip][m] * nninv * nninv;
        }
      }
    }
  } else {
    // TODO: error! too many neighbors for calculating normals
  }
}

// calculate the van der Waals force and energy
static __device__ void calc_vdW(
  float r,
  float rinv,
  float rsq,
  float d,
  float d_Seff,
  float C_6,
  float Tap,
  float dTap,
  float &p2_vdW,
  float &f2_vdW)
{
  float r2inv, r6inv, r8inv;
  double TSvdw, TSvdwinv_double;
  float Vilp, TSvdwinv_float;
  float fpair, fsum;

  r2inv = 1.0f / rsq;
  r6inv = r2inv * r2inv * r2inv;
  r8inv = r2inv * r6inv;

  // TSvdw = 1.0 + exp(-d_Seff * r + d);
  // use double to avoid inf from exp function
  TSvdw = 1.0 + exp((double) (-d_Seff * r + d));
  TSvdwinv_double = 1.0 / TSvdw;
  TSvdwinv_float = (float) TSvdwinv_double;
  Vilp = -C_6 * r6inv * TSvdwinv_float;

  // derivatives
  // fpair = -6.0 * C_6 * r8inv * TSvdwinv + \
  //   C_6 * d_Seff * (TSvdw - 1.0) * TSvdwinv * TSvdwinv * r8inv * r;
  fpair = (-6.0f + d_Seff * (1.0f - TSvdwinv_float) * r ) * C_6 * TSvdwinv_float * r8inv;
  fsum = fpair * Tap - Vilp * dTap * rinv;

  p2_vdW = Tap * Vilp;
  f2_vdW = fsum;
  
}

// force evaluation kernel
static __global__ void gpu_find_force(
  ILP_CBN_Para ilp_para,
  const int number_of_particles,
  const int N1,
  const int N2,
  const Box box,
  const int *g_neighbor_number,
  const int *g_neighbor_list,
  int *g_ilp_neighbor_number,
  int *g_ilp_neighbor_list,
  const int *group_label,
  const int *g_type,
  const double *__restrict__ g_x,
  const double *__restrict__ g_y,
  const double *__restrict__ g_z,
  double *g_fx,
  double *g_fy,
  double *g_fz,
  double *g_virial,
  double *g_potential,
  float *g_f12x,
  float *g_f12y,
  float *g_f12z,
  float *g_f12x_ilp_neigh,
  float *g_f12y_ilp_neigh,
  float *g_f12z_ilp_neigh)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index
  float s_fx = 0.0f;                                   // force_x
  float s_fy = 0.0f;                                   // force_y
  float s_fz = 0.0f;                                   // force_z
  float s_pe = 0.0f;                                   // potential energy
  float s_sxx = 0.0f;                                  // virial_stress_xx
  float s_sxy = 0.0f;                                  // virial_stress_xy
  float s_sxz = 0.0f;                                  // virial_stress_xz
  float s_syx = 0.0f;                                  // virial_stress_yx
  float s_syy = 0.0f;                                  // virial_stress_yy
  float s_syz = 0.0f;                                  // virial_stress_yz
  float s_szx = 0.0f;                                  // virial_stress_zx
  float s_szy = 0.0f;                                  // virial_stress_zy
  float s_szz = 0.0f;                                  // virial_stress_zz

  float r = 0.0f;
  float rsq = 0.0f;
  float Rcut = 0.0f;

  if (n1 < N2) {
    double x12d, y12d, z12d;
    float x12f, y12f, z12f;
    int neighor_number = g_neighbor_number[n1];
    int type1 = g_type[n1];
    double x1 = g_x[n1];
    double y1 = g_y[n1];
    double z1 = g_z[n1];

    int index_ilp_vec[3] = {n1, n1 + number_of_particles, n1 + (number_of_particles << 1)};
    float fk_temp[9] = {0.0f};

    float delkix_half[3] = {0.0f, 0.0f, 0.0f};
    float delkiy_half[3] = {0.0f, 0.0f, 0.0f};
    float delkiz_half[3] = {0.0f, 0.0f, 0.0f};

    // calculate the normal
    int cont = 0;
    float normal[3];
    float dnormdri[3][3];
    float dnormal[3][3][3];

    float vet[3][3];
    int id, ip, m;
    for (id = 0; id < 3; ++id) {
      normal[id] = 0.0f;
      for (ip = 0; ip < 3; ++ip) {
        vet[id][ip] = 0.0f;
        dnormdri[id][ip] = 0.0f;
        for (m = 0; m < 3; ++m) {
          dnormal[id][ip][m] = 0.0f;
        }
      }
    }

    int ilp_neighbor_number = g_ilp_neighbor_number[n1];
    for (int i1 = 0; i1 < ilp_neighbor_number; ++i1) {
      int n2_ilp = g_ilp_neighbor_list[n1 + number_of_particles * i1];
      x12d = g_x[n2_ilp] - x1;
      y12d = g_y[n2_ilp] - y1;
      z12d = g_z[n2_ilp] - z1;
      apply_mic(box, x12d, y12d, z12d);
      vet[cont][0] = float(x12d);
      vet[cont][1] = float(y12d);
      vet[cont][2] = float(z12d);
      ++cont;

      delkix_half[i1] = float(x12d) * 0.5f;
      delkiy_half[i1] = float(y12d) * 0.5f;
      delkiz_half[i1] = float(z12d) * 0.5f;
    }

    calc_normal(vet, cont, normal, dnormdri, dnormal);

    // calculate energy and force
    for (int i1 = 0; i1 < neighor_number; ++i1) {
      int index = n1 + number_of_particles * i1;
      int n2 = g_neighbor_list[index];
      int type2 = g_type[n2];

      x12d = g_x[n2] - x1;
      y12d = g_y[n2] - y1;
      z12d = g_z[n2] - z1;
      apply_mic(box, x12d, y12d, z12d);

      // save x12, y12, z12 in float
      x12f = float(x12d);
      y12f = float(y12d);
      z12f = float(z12d);

      // calculate distance between atoms
      rsq = x12f * x12f + y12f * y12f + z12f * z12f;
      r = sqrtf(rsq);
      Rcut = ilp_para.rcut_global[type1][type2];


      if (r >= Rcut) {
        continue;
      }

      // calc att
      float Tap, dTap, rinv;
      float Rcutinv = 1.0f / Rcut;
      rinv = 1.0f / r;
      Tap = calc_Tap(r, Rcutinv);
      dTap = calc_dTap(r, Rcut, Rcutinv);

      float p2_vdW, f2_vdW;
      calc_vdW(
        r,
        rinv,
        rsq,
        ilp_para.d[type1][type2],
        ilp_para.d_Seff[type1][type2],
        ilp_para.C_6[type1][type2],
        Tap,
        dTap,
        p2_vdW,
        f2_vdW);
      
      float f12x = -f2_vdW * x12f * 0.5f;
      float f12y = -f2_vdW * y12f * 0.5f;
      float f12z = -f2_vdW * z12f * 0.5f;
      float f21x = -f12x;
      float f21y = -f12y;
      float f21z = -f12z;

      s_fx += f12x - f21x;
      s_fy += f12y - f21y;
      s_fz += f12z - f21z;

      s_pe += p2_vdW * 0.5f;
      s_sxx += x12f * f21x;
      s_sxy += x12f * f21y;
      s_sxz += x12f * f21z;
      s_syx += y12f * f21x;
      s_syy += y12f * f21y;
      s_syz += y12f * f21z;
      s_szx += z12f * f21x;
      s_szy += z12f * f21y;
      s_szz += z12f * f21z;

      
      // calc rep
      float CC = ilp_para.CC[type1][type2];
      float lambda_ = ilp_para.lambda[type1][type2];
      float delta2inv = ilp_para.delta2inv[type1][type2];
      float epsilon = ilp_para.epsilon[type1][type2];
      float z0 = ilp_para.z0[type1][type2];
      // calc_rep
      float prodnorm1, rhosq1, rdsq1, exp0, exp1, frho1, Erep, Vilp;
      float fpair, fpair1, fsum, delx, dely, delz, fkcx, fkcy, fkcz;
      float dprodnorm1[3] = {0.0f, 0.0f, 0.0f};
      float fp1[3] = {0.0f, 0.0f, 0.0f};
      float fprod1[3] = {0.0f, 0.0f, 0.0f};
      float fk[3] = {0.0f, 0.0f, 0.0f};

      delx = -x12f;
      dely = -y12f;
      delz = -z12f;

      float delx_half = delx * 0.5f;
      float dely_half = dely * 0.5f;
      float delz_half = delz * 0.5f;

      // calculate the transverse distance
      prodnorm1 = normal[0] * delx + normal[1] * dely + normal[2] * delz;
      rhosq1 = rsq - prodnorm1 * prodnorm1;
      rdsq1 = rhosq1 * delta2inv;

      // store exponents
      // exp0 = exp(-lambda_ * (r - z0));
      // exp1 = exp(-rdsq1);
      exp0 = expf(-lambda_ * (r - z0));
      exp1 = expf(-rdsq1);

      frho1 = exp1 * CC;
      Erep = 0.5f * epsilon + frho1;
      Vilp = exp0 * Erep;

      // derivatives
      fpair = lambda_ * exp0 * rinv * Erep;
      fpair1 = 2.0f * exp0 * frho1 * delta2inv;
      fsum = fpair + fpair1;

      float prodnorm1_m_fpair1 = prodnorm1 * fpair1;
      float Vilp_m_dTap_m_rinv = Vilp * dTap * rinv;

      // derivatives of the product of rij and ni, the resutl is a vector
      dprodnorm1[0] = 
        dnormdri[0][0] * delx + dnormdri[1][0] * dely + dnormdri[2][0] * delz;
      dprodnorm1[1] = 
        dnormdri[0][1] * delx + dnormdri[1][1] * dely + dnormdri[2][1] * delz;
      dprodnorm1[2] = 
        dnormdri[0][2] * delx + dnormdri[1][2] * dely + dnormdri[2][2] * delz;
      // fp1[0] = prodnorm1 * normal[0] * fpair1;
      // fp1[1] = prodnorm1 * normal[1] * fpair1;
      // fp1[2] = prodnorm1 * normal[2] * fpair1;
      // fprod1[0] = prodnorm1 * dprodnorm1[0] * fpair1;
      // fprod1[1] = prodnorm1 * dprodnorm1[1] * fpair1;
      // fprod1[2] = prodnorm1 * dprodnorm1[2] * fpair1;
      fp1[0] = prodnorm1_m_fpair1 * normal[0];
      fp1[1] = prodnorm1_m_fpair1 * normal[1];
      fp1[2] = prodnorm1_m_fpair1 * normal[2];
      fprod1[0] = prodnorm1_m_fpair1 * dprodnorm1[0];
      fprod1[1] = prodnorm1_m_fpair1 * dprodnorm1[1];
      fprod1[2] = prodnorm1_m_fpair1 * dprodnorm1[2];

      // fkcx = (delx * fsum - fp1[0]) * Tap - Vilp * dTap * delx * rinv;
      // fkcy = (dely * fsum - fp1[1]) * Tap - Vilp * dTap * dely * rinv;
      // fkcz = (delz * fsum - fp1[2]) * Tap - Vilp * dTap * delz * rinv;
      fkcx = (delx * fsum - fp1[0]) * Tap - Vilp_m_dTap_m_rinv * delx;
      fkcy = (dely * fsum - fp1[1]) * Tap - Vilp_m_dTap_m_rinv * dely;
      fkcz = (delz * fsum - fp1[2]) * Tap - Vilp_m_dTap_m_rinv * delz;

      s_fx += fkcx - fprod1[0] * Tap;
      s_fy += fkcy - fprod1[1] * Tap;
      s_fz += fkcz - fprod1[2] * Tap;

      g_f12x[index] = fkcx;
      g_f12y[index] = fkcy;
      g_f12z[index] = fkcz;

      float minus_prodnorm1_m_fpair1_m_Tap = -prodnorm1 * fpair1 * Tap;
      for (int kk = 0; kk < ilp_neighbor_number; ++kk) {
        // int index_ilp = n1 + number_of_particles * kk;
        // int n2_ilp = g_ilp_neighbor_list[index_ilp];
        // if (n2_ilp_vec[kk] == n1) continue;
        // derivatives of the product of rij and ni respect to rk, k=0,1,2, where atom k is the neighbors of atom i
        dprodnorm1[0] = dnormal[0][0][kk] * delx + dnormal[1][0][kk] * dely +
            dnormal[2][0][kk] * delz;
        dprodnorm1[1] = dnormal[0][1][kk] * delx + dnormal[1][1][kk] * dely +
            dnormal[2][1][kk] * delz;
        dprodnorm1[2] = dnormal[0][2][kk] * delx + dnormal[1][2][kk] * dely +
            dnormal[2][2][kk] * delz;
        // fk[0] = (-prodnorm1 * dprodnorm1[0] * fpair1) * Tap;
        // fk[1] = (-prodnorm1 * dprodnorm1[1] * fpair1) * Tap;
        // fk[2] = (-prodnorm1 * dprodnorm1[2] * fpair1) * Tap;
        fk[0] = minus_prodnorm1_m_fpair1_m_Tap * dprodnorm1[0];
        fk[1] = minus_prodnorm1_m_fpair1_m_Tap * dprodnorm1[1];
        fk[2] = minus_prodnorm1_m_fpair1_m_Tap * dprodnorm1[2];

        // g_f12x_ilp_neigh[index_ilp_vec[kk]] += fk[0];
        // g_f12y_ilp_neigh[index_ilp_vec[kk]] += fk[1];
        // g_f12z_ilp_neigh[index_ilp_vec[kk]] += fk[2];
        fk_temp[kk] += fk[0];
        fk_temp[kk + 3] += fk[1];
        fk_temp[kk + 6] += fk[2];

        // delki[0] = g_x[n2_ilp] - x1;
        // delki[1] = g_y[n2_ilp] - y1;
        // delki[2] = g_z[n2_ilp] - z1;
        // apply_mic(box, delki[0], delki[1], delki[2]);

        // s_sxx += delki[0] * fk[0] * 0.5;
        // s_sxy += delki[0] * fk[1] * 0.5;
        // s_sxz += delki[0] * fk[2] * 0.5;
        // s_syx += delki[1] * fk[0] * 0.5;
        // s_syy += delki[1] * fk[1] * 0.5;
        // s_syz += delki[1] * fk[2] * 0.5;
        // s_szx += delki[2] * fk[0] * 0.5;
        // s_szy += delki[2] * fk[1] * 0.5;
        // s_szz += delki[2] * fk[2] * 0.5;

        s_sxx += delkix_half[kk] * fk[0];
        s_sxy += delkix_half[kk] * fk[1];
        s_sxz += delkix_half[kk] * fk[2];
        s_syx += delkiy_half[kk] * fk[0];
        s_syy += delkiy_half[kk] * fk[1];
        s_syz += delkiy_half[kk] * fk[2];
        s_szx += delkiz_half[kk] * fk[0];
        s_szy += delkiz_half[kk] * fk[1];
        s_szz += delkiz_half[kk] * fk[2];
      }
      s_pe += Tap * Vilp;
      s_sxx += delx_half * fkcx;
      s_sxy += delx_half * fkcy;
      s_sxz += delx_half * fkcz;
      s_syx += dely_half * fkcx;
      s_syy += dely_half * fkcy;
      s_syz += dely_half * fkcz;
      s_szx += delz_half * fkcx;
      s_szy += delz_half * fkcy;
      s_szz += delz_half * fkcz;
    }

    // save force
    g_fx[n1] += s_fx;
    g_fy[n1] += s_fy;
    g_fz[n1] += s_fz;
    g_f12x_ilp_neigh[index_ilp_vec[0]] = fk_temp[0];
    g_f12x_ilp_neigh[index_ilp_vec[1]] = fk_temp[1];
    g_f12x_ilp_neigh[index_ilp_vec[2]] = fk_temp[2];
    g_f12y_ilp_neigh[index_ilp_vec[0]] = fk_temp[3];
    g_f12y_ilp_neigh[index_ilp_vec[1]] = fk_temp[4];
    g_f12y_ilp_neigh[index_ilp_vec[2]] = fk_temp[5];
    g_f12z_ilp_neigh[index_ilp_vec[0]] = fk_temp[6];
    g_f12z_ilp_neigh[index_ilp_vec[1]] = fk_temp[7];
    g_f12z_ilp_neigh[index_ilp_vec[2]] = fk_temp[8];

    // save virial
    // xx xy xz    0 3 4
    // yx yy yz    6 1 5
    // zx zy zz    7 8 2
    g_virial[n1 + 0 * number_of_particles] += s_sxx;
    g_virial[n1 + 1 * number_of_particles] += s_syy;
    g_virial[n1 + 2 * number_of_particles] += s_szz;
    g_virial[n1 + 3 * number_of_particles] += s_sxy;
    g_virial[n1 + 4 * number_of_particles] += s_sxz;
    g_virial[n1 + 5 * number_of_particles] += s_syz;
    g_virial[n1 + 6 * number_of_particles] += s_syx;
    g_virial[n1 + 7 * number_of_particles] += s_szx;
    g_virial[n1 + 8 * number_of_particles] += s_szy;

    // save potential
    g_potential[n1] += s_pe;

  }
}

// build a neighbor list for reducing force
static __global__ void build_reduce_neighbor_list(
  const int number_of_particles,
  const int N1,
  const int N2,
  const int *g_neighbor_number,
  const int *g_neighbor_list,
  int *g_reduce_neighbor_list)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (N1 < N2) {
    int neighbor_number = g_neighbor_number[n1];
    int l, r, m, tmp_value;
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int index = n1 + i1 * number_of_particles;
      int n2 = g_neighbor_list[index];

      l = 0;
      r = g_neighbor_number[n2];
      while (l < r) {
        m = (l + r) >> 1;
        tmp_value = g_neighbor_list[n2 + number_of_particles * m];
        if (tmp_value < n1) {
          l = m + 1;
        } else if (tmp_value > n1) {
          r = m - 1;
        } else {
          break;
        }
      }
      g_reduce_neighbor_list[index] = (l + r) >> 1;
    }
  }
}

// reduce the rep force
static __global__ void reduce_force_many_body(
  const int number_of_particles,
  const int N1,
  const int N2,
  const Box box,
  const int *g_neighbor_number,
  const int *g_neighbor_list,
  int *g_reduce_neighbor_list,
  int *g_ilp_neighbor_number,
  int *g_ilp_neighbor_list,
  const double *__restrict__ g_x,
  const double *__restrict__ g_y,
  const double *__restrict__ g_z,
  double *g_fx,
  double *g_fy,
  double *g_fz,
  double *g_virial,
  float *g_f12x,
  float *g_f12y,
  float *g_f12z,
  float *g_f12x_ilp_neigh,
  float *g_f12y_ilp_neigh,
  float *g_f12z_ilp_neigh)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index
  float s_fx = 0.0f;                                   // force_x
  float s_fy = 0.0f;                                   // force_y
  float s_fz = 0.0f;                                   // force_z
  float s_sxx = 0.0f;                                  // virial_stress_xx
  float s_sxy = 0.0f;                                  // virial_stress_xy
  float s_sxz = 0.0f;                                  // virial_stress_xz
  float s_syx = 0.0f;                                  // virial_stress_yx
  float s_syy = 0.0f;                                  // virial_stress_yy
  float s_syz = 0.0f;                                  // virial_stress_yz
  float s_szx = 0.0f;                                  // virial_stress_zx
  float s_szy = 0.0f;                                  // virial_stress_zy
  float s_szz = 0.0f;                                  // virial_stress_zz


  if (n1 < N2) {
    double x12d, y12d, z12d;
    float x12f, y12f, z12f;
    int neighbor_number_1 = g_neighbor_number[n1];
    double x1 = g_x[n1];
    double y1 = g_y[n1];
    double z1 = g_z[n1];

    // calculate energy and force
    for (int i1 = 0; i1 < neighbor_number_1; ++i1) {
      int index = n1 + number_of_particles * i1;
      int n2 = g_neighbor_list[index];

      x12d = g_x[n2] - x1;
      y12d = g_y[n2] - y1;
      z12d = g_z[n2] - z1;
      apply_mic(box, x12d, y12d, z12d);
      x12f = float(x12d);
      y12f = float(y12d);
      z12f = float(z12d);

      index = n2 + number_of_particles * g_reduce_neighbor_list[index];
      float f21x = g_f12x[index];
      float f21y = g_f12y[index];
      float f21z = g_f12z[index];

      s_fx -= f21x;
      s_fy -= f21y;
      s_fz -= f21z;

      // per-atom virial
      s_sxx += x12f * f21x * 0.5f;
      s_sxy += x12f * f21y * 0.5f;
      s_sxz += x12f * f21z * 0.5f;
      s_syx += y12f * f21x * 0.5f;
      s_syy += y12f * f21y * 0.5f;
      s_syz += y12f * f21z * 0.5f;
      s_szx += z12f * f21x * 0.5f;
      s_szy += z12f * f21y * 0.5f;
      s_szz += z12f * f21z * 0.5f;
    }

    int ilp_neighbor_number_1 = g_ilp_neighbor_number[n1];

    for (int i1 = 0; i1 < ilp_neighbor_number_1; ++i1) {
      int index = n1 + number_of_particles * i1;
      int n2 = g_ilp_neighbor_list[index];
      int ilp_neighor_number_2 = g_ilp_neighbor_number[n2];

      x12d = g_x[n2] - x1;
      y12d = g_y[n2] - y1;
      z12d = g_z[n2] - z1;
      apply_mic(box, x12d, y12d, z12d);
      x12f = float(x12d);
      y12f = float(y12d);
      z12f = float(z12d);

      int offset = 0;
      for (int k = 0; k < ilp_neighor_number_2; ++k) {
        if (n1 == g_ilp_neighbor_list[n2 + number_of_particles * k]) {
          offset = k;
          break;
        }
      }
      index = n2 + number_of_particles * offset;
      float f21x = g_f12x_ilp_neigh[index];
      float f21y = g_f12y_ilp_neigh[index];
      float f21z = g_f12z_ilp_neigh[index];

      s_fx += f21x;
      s_fy += f21y;
      s_fz += f21z;

      // per-atom virial
      s_sxx += -x12f * f21x * 0.5f;
      s_sxy += -x12f * f21y * 0.5f;
      s_sxz += -x12f * f21z * 0.5f;
      s_syx += -y12f * f21x * 0.5f;
      s_syy += -y12f * f21y * 0.5f;
      s_syz += -y12f * f21z * 0.5f;
      s_szx += -z12f * f21x * 0.5f;
      s_szy += -z12f * f21y * 0.5f;
      s_szz += -z12f * f21z * 0.5f;
    }

    // save force
    g_fx[n1] += s_fx;
    g_fy[n1] += s_fy;
    g_fz[n1] += s_fz;

    // save virial
    // xx xy xz    0 3 4
    // yx yy yz    6 1 5
    // zx zy zz    7 8 2
    g_virial[n1 + 0 * number_of_particles] += s_sxx;
    g_virial[n1 + 1 * number_of_particles] += s_syy;
    g_virial[n1 + 2 * number_of_particles] += s_szz;
    g_virial[n1 + 3 * number_of_particles] += s_sxy;
    g_virial[n1 + 4 * number_of_particles] += s_sxz;
    g_virial[n1 + 5 * number_of_particles] += s_syz;
    g_virial[n1 + 6 * number_of_particles] += s_syx;
    g_virial[n1 + 7 * number_of_particles] += s_szx;
    g_virial[n1 + 8 * number_of_particles] += s_szy;
  }
}

// Tersoff 1988 term

static __device__ void
find_fr_and_frp(int i, const double* __restrict__ ters, double d12, double& fr, double& frp)
{
  fr = LDG(ters, i + A) * exp(-LDG(ters, i + LAMBDA) * d12);
  frp = -LDG(ters, i + LAMBDA) * fr;
}

static __device__ void
find_fa_and_fap(int i, const double* __restrict__ ters, double d12, double& fa, double& fap)
{
  fa = LDG(ters, i + B) * exp(-LDG(ters, i + MU) * d12);
  fap = -LDG(ters, i + MU) * fa;
}

static __device__ void find_fa(int i, const double* __restrict__ ters, double d12, double& fa)
{
  fa = LDG(ters, i + B) * exp(-LDG(ters, i + MU) * d12);
}

static __device__ void
find_fc_and_fcp(int i, const double* __restrict__ ters, double d12, double& fc, double& fcp)
{
  if (d12 < LDG(ters, i + R1)) {
    fc = 1.0;
    fcp = 0.0;
  } else if (d12 < LDG(ters, i + R2)) {
    fc = cos(LDG(ters, i + PI_FACTOR) * (d12 - LDG(ters, i + R1))) * 0.5 + 0.5;
    fcp =
      -sin(LDG(ters, i + PI_FACTOR) * (d12 - LDG(ters, i + R1))) * LDG(ters, i + PI_FACTOR) * 0.5;
  } else {
    fc = 0.0;
    fcp = 0.0;
  }
}

static __device__ void find_fc(int i, const double* __restrict__ ters, double d12, double& fc)
{
  if (d12 < LDG(ters, i + R1)) {
    fc = 1.0;
  } else if (d12 < LDG(ters, i + R2)) {
    fc = cos(LDG(ters, i + PI_FACTOR) * (d12 - LDG(ters, i + R1))) * 0.5 + 0.5;
  } else {
    fc = 0.0;
  }
}

static __device__ void
find_g_and_gp(int i, const double* __restrict__ ters, double cos, double& g, double& gp)
{
  double temp = LDG(ters, i + D2) + (cos - LDG(ters, i + H)) * (cos - LDG(ters, i + H));
  g = LDG(ters, i + GAMMA) * (LDG(ters, i + ONE_PLUS_C2OVERD2) - LDG(ters, i + C2) / temp);
  gp = LDG(ters, i + GAMMA) * (2.0 * LDG(ters, i + C2) * (cos - LDG(ters, i + H)) / (temp * temp));
}

static __device__ void find_g(int i, const double* __restrict__ ters, double cos, double& g)
{
  double temp = LDG(ters, i + D2) + (cos - LDG(ters, i + H)) * (cos - LDG(ters, i + H));
  g = LDG(ters, i + GAMMA) * (LDG(ters, i + ONE_PLUS_C2OVERD2) - LDG(ters, i + C2) / temp);
}

static __device__ void
find_e_and_ep(int i, const double* __restrict__ ters, double d12, double d13, double& e, double& ep)
{
  if (LDG(ters, i + ALPHA) < EPSILON) {
    e = 1.0;
    ep = 0.0;
  } else {
    double r = d12 - d13;
    if (LDG(ters, i + M) > 2.0) // if m == 3.0
    {
      e = exp(LDG(ters, i + ALPHA) * r * r * r);
      ep = LDG(ters, i + ALPHA) * 3.0 * r * r * e;
    } else {
      e = exp(LDG(ters, i + ALPHA) * r);
      ep = LDG(ters, i + ALPHA) * e;
    }
  }
}

static __device__ void
find_e(int i, const double* __restrict__ ters, double d12, double d13, double& e)
{
  if (LDG(ters, i + ALPHA) < EPSILON) {
    e = 1.0;
  } else {
    double r = d12 - d13;
    if (LDG(ters, i + M) > 2.0) {
      e = exp(LDG(ters, i + ALPHA) * r * r * r);
    } else {
      e = exp(LDG(ters, i + ALPHA) * r);
    }
  }
}

// step 1: pre-compute all the bond-order functions and their derivatives
static __global__ void find_force_tersoff_step1(
  const int number_of_particles,
  const int N1,
  const int N2,
  const Box box,
  const int num_types,
  const int* g_neighbor_number,
  const int* g_neighbor_list,
  const int* g_type,
  const double* __restrict__ ters,
  const double* __restrict__ g_x,
  const double* __restrict__ g_y,
  const double* __restrict__ g_z,
  double* g_b,
  double* g_bp)
{
  int num_types2 = num_types * num_types;
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (n1 < N2) {
    int neighbor_number = g_neighbor_number[n1];
    int type1 = g_type[n1];
    double x1 = LDG(g_x, n1);
    double y1 = LDG(g_y, n1);
    double z1 = LDG(g_z, n1);
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int n2 = g_neighbor_list[n1 + number_of_particles * i1];
      int type2 = g_type[n2];
      double x12 = g_x[n2] - x1;
      double y12 = g_y[n2] - y1;
      double z12 = g_z[n2] - z1;
      apply_mic(box, x12, y12, z12);
      double d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
      double zeta = 0.0;
      for (int i2 = 0; i2 < neighbor_number; ++i2) {
        int n3 = g_neighbor_list[n1 + number_of_particles * i2];
        if (n3 == n2) {
          continue;
        } // ensure that n3 != n2
        int type3 = g_type[n3];
        double x13 = g_x[n3] - x1;
        double y13 = g_y[n3] - y1;
        double z13 = g_z[n3] - z1;
        apply_mic(box, x13, y13, z13);
        double d13 = sqrt(x13 * x13 + y13 * y13 + z13 * z13);
        double cos123 = (x12 * x13 + y12 * y13 + z12 * z13) / (d12 * d13);
        double fc_ijk_13, g_ijk, e_ijk_12_13;
        int ijk = type1 * num_types2 + type2 * num_types + type3;
        if (d13 > LDG(ters, ijk * NUM_PARAMS + R2)) {
          continue;
        }
        find_fc(ijk * NUM_PARAMS, ters, d13, fc_ijk_13);
        find_g(ijk * NUM_PARAMS, ters, cos123, g_ijk);
        find_e(ijk * NUM_PARAMS, ters, d12, d13, e_ijk_12_13);
        zeta += fc_ijk_13 * g_ijk * e_ijk_12_13;
      }
      double bzn, b_ijj;
      int ijj = type1 * num_types2 + type2 * num_types + type2;
      bzn = pow(LDG(ters, ijj * NUM_PARAMS + BETA) * zeta, LDG(ters, ijj * NUM_PARAMS + EN));
      b_ijj = pow(1.0 + bzn, LDG(ters, ijj * NUM_PARAMS + MINUS_HALF_OVER_N));
      if (zeta < 1.0e-16) // avoid division by 0
      {
        g_b[i1 * number_of_particles + n1] = 1.0;
        g_bp[i1 * number_of_particles + n1] = 0.0;
      } else {
        g_b[i1 * number_of_particles + n1] = b_ijj;
        g_bp[i1 * number_of_particles + n1] = -b_ijj * bzn * 0.5 / ((1.0 + bzn) * zeta);
      }
    }
  }
}

// step 2: calculate all the partial forces dU_i/dr_ij
static __global__ void find_force_tersoff_step2(
  const int number_of_particles,
  const int N1,
  const int N2,
  Box box,
  const int num_types,
  const int* g_neighbor_number,
  const int* g_neighbor_list,
  const int* g_type,
  const double* __restrict__ ters,
  const double* __restrict__ g_b,
  const double* __restrict__ g_bp,
  const double* __restrict__ g_x,
  const double* __restrict__ g_y,
  const double* __restrict__ g_z,
  double* g_potential,
  double* g_f12x,
  double* g_f12y,
  double* g_f12z)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  int num_types2 = num_types * num_types;
  if (n1 < N2) {
    int neighbor_number = g_neighbor_number[n1];
    int type1 = g_type[n1];
    double x1 = LDG(g_x, n1);
    double y1 = LDG(g_y, n1);
    double z1 = LDG(g_z, n1);
    double pot_energy = 0.0;
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int index = i1 * number_of_particles + n1;
      int n2 = g_neighbor_list[index];
      int type2 = g_type[n2];

      double x12 = g_x[n2] - x1;
      double y12 = g_y[n2] - y1;
      double z12 = g_z[n2] - z1;
      apply_mic(box, x12, y12, z12);
      double d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
      double d12inv = 1.0 / d12;
      double fc_ijj_12, fcp_ijj_12;
      double fa_ijj_12, fap_ijj_12, fr_ijj_12, frp_ijj_12;
      int ijj = type1 * num_types2 + type2 * num_types + type2;
      find_fc_and_fcp(ijj * NUM_PARAMS, ters, d12, fc_ijj_12, fcp_ijj_12);
      find_fa_and_fap(ijj * NUM_PARAMS, ters, d12, fa_ijj_12, fap_ijj_12);
      find_fr_and_frp(ijj * NUM_PARAMS, ters, d12, fr_ijj_12, frp_ijj_12);

      // (i,j) part
      double b12 = LDG(g_b, index);
      double factor3 =
        (fcp_ijj_12 * (fr_ijj_12 - b12 * fa_ijj_12) + fc_ijj_12 * (frp_ijj_12 - b12 * fap_ijj_12)) *
        d12inv;
      double f12x = x12 * factor3 * 0.5;
      double f12y = y12 * factor3 * 0.5;
      double f12z = z12 * factor3 * 0.5;

      // accumulate potential energy
      pot_energy += fc_ijj_12 * (fr_ijj_12 - b12 * fa_ijj_12) * 0.5;

      // (i,j,k) part
      double bp12 = LDG(g_bp, index);
      for (int i2 = 0; i2 < neighbor_number; ++i2) {
        int index_2 = n1 + number_of_particles * i2;
        int n3 = g_neighbor_list[index_2];
        if (n3 == n2) {
          continue;
        }
        int type3 = g_type[n3];
        double x13 = g_x[n3] - x1;
        double y13 = g_y[n3] - y1;
        double z13 = g_z[n3] - z1;
        apply_mic(box, x13, y13, z13);
        double d13 = sqrt(x13 * x13 + y13 * y13 + z13 * z13);
        double fc_ikk_13, fc_ijk_13, fa_ikk_13, fc_ikj_12, fcp_ikj_12;
        int ikj = type1 * num_types2 + type3 * num_types + type2;
        int ikk = type1 * num_types2 + type3 * num_types + type3;
        int ijk = type1 * num_types2 + type2 * num_types + type3;
        find_fc(ikk * NUM_PARAMS, ters, d13, fc_ikk_13);
        find_fc(ijk * NUM_PARAMS, ters, d13, fc_ijk_13);
        find_fa(ikk * NUM_PARAMS, ters, d13, fa_ikk_13);
        find_fc_and_fcp(ikj * NUM_PARAMS, ters, d12, fc_ikj_12, fcp_ikj_12);
        double bp13 = LDG(g_bp, index_2);
        double one_over_d12d13 = 1.0 / (d12 * d13);
        double cos123 = (x12 * x13 + y12 * y13 + z12 * z13) * one_over_d12d13;
        double cos123_over_d12d12 = cos123 * d12inv * d12inv;
        double g_ijk, gp_ijk;
        find_g_and_gp(ijk * NUM_PARAMS, ters, cos123, g_ijk, gp_ijk);

        double g_ikj, gp_ikj;
        find_g_and_gp(ikj * NUM_PARAMS, ters, cos123, g_ikj, gp_ikj);

        // exp with d12 - d13
        double e_ijk_12_13, ep_ijk_12_13;
        find_e_and_ep(ijk * NUM_PARAMS, ters, d12, d13, e_ijk_12_13, ep_ijk_12_13);

        // exp with d13 - d12
        double e_ikj_13_12, ep_ikj_13_12;
        find_e_and_ep(ikj * NUM_PARAMS, ters, d13, d12, e_ikj_13_12, ep_ikj_13_12);

        // derivatives with cosine
        double dc = -fc_ijj_12 * bp12 * fa_ijj_12 * fc_ijk_13 * gp_ijk * e_ijk_12_13 +
                    -fc_ikj_12 * bp13 * fa_ikk_13 * fc_ikk_13 * gp_ikj * e_ikj_13_12;
        // derivatives with rij
        double dr = (-fc_ijj_12 * bp12 * fa_ijj_12 * fc_ijk_13 * g_ijk * ep_ijk_12_13 +
                     (-fcp_ikj_12 * bp13 * fa_ikk_13 * g_ikj * e_ikj_13_12 +
                      fc_ikj_12 * bp13 * fa_ikk_13 * g_ikj * ep_ikj_13_12) *
                       fc_ikk_13) *
                    d12inv;
        double cos_d = x13 * one_over_d12d13 - x12 * cos123_over_d12d12;
        f12x += (x12 * dr + dc * cos_d) * 0.5;
        cos_d = y13 * one_over_d12d13 - y12 * cos123_over_d12d12;
        f12y += (y12 * dr + dc * cos_d) * 0.5;
        cos_d = z13 * one_over_d12d13 - z12 * cos123_over_d12d12;
        f12z += (z12 * dr + dc * cos_d) * 0.5;
      }
      g_f12x[index] = f12x;
      g_f12y[index] = f12y;
      g_f12z[index] = f12z;
    }
    // save potential
    g_potential[n1] += pot_energy;
  }
}


// define the pure virtual func
void ILP_TERSOFF::compute(
  Box &box,
  const GPU_Vector<int> &type,
  const GPU_Vector<double> &position_per_atom,
  GPU_Vector<double> &potential_per_atom,
  GPU_Vector<double> &force_per_atom,
  GPU_Vector<double> &virial_per_atom)
{
  // nothing
}

//#define USE_FIXED_NEIGHBOR 1
#define UPDATE_TEMP 10
#define BIG_ILP_CUTOFF_SQUARE 50.0
// find force and related quantities
void ILP_TERSOFF::compute_ilp(
  Box &box,
  const GPU_Vector<int> &type,
  const GPU_Vector<double> &position_per_atom,
  GPU_Vector<double> &potential_per_atom,
  GPU_Vector<double> &force_per_atom,
  GPU_Vector<double> &virial_per_atom,
  std::vector<Group> &group)
{
  const int number_of_atoms = type.size();
  int grid_size = (N2 - N1 - 1) / BLOCK_SIZE_FORCE + 1;

  // ILP group labels
  const int *group_label = group[ilp_group_method].label.data();

#ifdef USE_FIXED_NEIGHBOR
  static int num_calls = 0;
  if (num_calls++ == 0) {
#endif
    find_neighbor_ilp(
      N1,
      N2,
      rc,
      BIG_ILP_CUTOFF_SQUARE,
      box,
      group_label,
      type,
      position_per_atom,
      ilp_data.cell_count,
      ilp_data.cell_count_sum,
      ilp_data.cell_contents,
      ilp_data.NN,
      ilp_data.NL,
      ilp_data.big_ilp_NN,
      ilp_data.big_ilp_NL);
    
    find_neighbor_SW(
      N1,
      N2,
      rc_tersoff,
      box,
      group_label,
      type,
      position_per_atom,
      tersoff_data.cell_count,
      tersoff_data.cell_count_sum,
      tersoff_data.cell_contents,
      tersoff_data.NN,
      tersoff_data.NL
    );

    build_reduce_neighbor_list<<<grid_size, BLOCK_SIZE_FORCE>>>(
      number_of_atoms,
      N1,
      N2,
      ilp_data.NN.data(),
      ilp_data.NL.data(),
      ilp_data.reduce_NL.data());
#ifdef USE_FIXED_NEIGHBOR
  }
  num_calls %= UPDATE_TEMP;
#endif

  const double* x = position_per_atom.data();
  const double* y = position_per_atom.data() + number_of_atoms;
  const double* z = position_per_atom.data() + number_of_atoms * 2;
  const int *NN = ilp_data.NN.data();
  const int *NL = ilp_data.NL.data();
  const int* big_ilp_NN = ilp_data.big_ilp_NN.data();
  const int* big_ilp_NL = ilp_data.big_ilp_NL.data();
  int *reduce_NL = ilp_data.reduce_NL.data();
  int *ilp_NL = ilp_data.ilp_NL.data();
  int *ilp_NN = ilp_data.ilp_NN.data();

  const int* NN_tersoff = tersoff_data.NN.data();
  const int* NL_tersoff = tersoff_data.NL.data();

  ilp_data.ilp_NL.fill(0);
  ilp_data.ilp_NN.fill(0);

  // find ILP neighbor list
  ILP_neighbor<<<grid_size, BLOCK_SIZE_FORCE>>>(
    number_of_atoms, N1, N2, box, big_ilp_NN, big_ilp_NL, \
    type.data(), ilp_para, x, y, z, ilp_NN, \
    ilp_NL, group_label);
  GPU_CHECK_KERNEL

  // initialize force of ilp neighbor temporary vector
  ilp_data.f12x_ilp_neigh.fill(0);
  ilp_data.f12y_ilp_neigh.fill(0);
  ilp_data.f12z_ilp_neigh.fill(0);
  ilp_data.f12x.fill(0);
  ilp_data.f12y.fill(0);
  ilp_data.f12z.fill(0);

  tersoff_data.f12x.fill(0);
  tersoff_data.f12y.fill(0);
  tersoff_data.f12z.fill(0);

  double *g_fx = force_per_atom.data();
  double *g_fy = force_per_atom.data() + number_of_atoms;
  double *g_fz = force_per_atom.data() + number_of_atoms * 2;
  double *g_virial = virial_per_atom.data();
  double *g_potential = potential_per_atom.data();
  float *g_f12x = ilp_data.f12x.data();
  float *g_f12y = ilp_data.f12y.data();
  float *g_f12z = ilp_data.f12z.data();
  float *g_f12x_ilp_neigh = ilp_data.f12x_ilp_neigh.data();
  float *g_f12y_ilp_neigh = ilp_data.f12y_ilp_neigh.data();
  float *g_f12z_ilp_neigh = ilp_data.f12z_ilp_neigh.data();

  gpu_find_force<<<grid_size, BLOCK_SIZE_FORCE>>>(
    ilp_para,
    number_of_atoms,
    N1,
    N2,
    box,
    NN,
    NL,
    ilp_NN,
    ilp_NL,
    group_label,
    type.data(),
    x,
    y,
    z,
    g_fx,
    g_fy,
    g_fz,
    g_virial,
    g_potential,
    g_f12x,
    g_f12y,
    g_f12z,
    g_f12x_ilp_neigh,
    g_f12y_ilp_neigh,
    g_f12z_ilp_neigh);
  GPU_CHECK_KERNEL

  reduce_force_many_body<<<grid_size, BLOCK_SIZE_FORCE>>>(
    number_of_atoms,
    N1,
    N2,
    box,
    NN,
    NL,
    reduce_NL,
    ilp_NN,
    ilp_NL,
    x,
    y,
    z,
    g_fx,
    g_fy,
    g_fz,
    g_virial,
    g_f12x,
    g_f12y,
    g_f12z,
    g_f12x_ilp_neigh,
    g_f12y_ilp_neigh,
    g_f12z_ilp_neigh);
    GPU_CHECK_KERNEL

  
  // pre-compute the bond order functions and their derivatives
  find_force_tersoff_step1<<<grid_size, BLOCK_SIZE_FORCE>>>(
    number_of_atoms,
    N1,
    N2,
    box,
    num_types,
    tersoff_data.NN.data(),
    tersoff_data.NL.data(),
    type.data(),
    ters.data(),
    position_per_atom.data(),
    position_per_atom.data() + number_of_atoms,
    position_per_atom.data() + number_of_atoms * 2,
    tersoff_data.b.data(),
    tersoff_data.bp.data());
  GPU_CHECK_KERNEL

  // pre-compute the partial forces
  find_force_tersoff_step2<<<grid_size, BLOCK_SIZE_FORCE>>>(
    number_of_atoms,
    N1,
    N2,
    box,
    num_types,
    tersoff_data.NN.data(),
    tersoff_data.NL.data(),
    type.data(),
    ters.data(),
    tersoff_data.b.data(),
    tersoff_data.bp.data(),
    position_per_atom.data(),
    position_per_atom.data() + number_of_atoms,
    position_per_atom.data() + number_of_atoms * 2,
    potential_per_atom.data(),
    tersoff_data.f12x.data(),
    tersoff_data.f12y.data(),
    tersoff_data.f12z.data());
  GPU_CHECK_KERNEL

  // the final step: calculate force and related quantities
  find_properties_many_body(
    box,
    tersoff_data.NN.data(),
    tersoff_data.NL.data(),
    tersoff_data.f12x.data(),
    tersoff_data.f12y.data(),
    tersoff_data.f12z.data(),
    position_per_atom,
    force_per_atom,
    virial_per_atom);
}