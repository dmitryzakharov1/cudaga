#include "cuda_ga.h"
#include "random.h"
#include <sm_11_atomic_functions.h>

//this runs the main loop of all the threads which will call insert_roulette, init_individual, and 
//calc_fitness until a solution is found or the max number of “generations” is reached for one 
//of the threads.
//this function assumes that pool has sizeof(chromo) * POOL_SIZE bytes allocated in gpu
//memory.
//when this returns the last “generation” of individuals will be stored in the pool in order of fitness
//best first.
__global__ void run_ga(mutex *lock, chromo *pool, unsigned *seeds)
{
	chromo locals[NUM_OFFSPRING + 1];
	chromo *parents = locals + 1;
	int i,j;
	int th_id = threadIdx.x + blockIdx.x * blockDim.x;
	unsigned seed = seeds[th_id];
	int retVal;
	int waitCount = 0;

	seeds[th_id] = 42;

/*
	if (th_id == 0) {
		for (i = 0; i < NUM_INDIVIDUALS; i++) {
			//init_individual(&pool[i], &seed);
			if (i & 0x01) {
				calc_fitness(&pool[i - 1], &seed);
			}
		}
		lock[1] = 0;
	} else {
		waitCount = 0;
		while (lock[1]) {
			waitCount++;
		}
	}
	__syncthreads();
*/
	retVal = 1;
	while (retVal) {
		if (0 == mutex_lock()) {
			for (i = 0; i < NUM_OFFSPRING; i++) {
				cpy_ind(&locals[i], &pool[i + th_id * NUM_OFFSPRING]);
			}
			seeds[th_id] = waitCount;
			mutex_unlock();
			retVal = 0;
		} else {
			for (j = 0; j < 5000 * grand(&seed); j++) {
				waitCount++;
			}
		}
	}
	for (i = 0; i < (NUM_OFFSPRING - 1); i += 2) {
		calc_fitness(&locals[i], &seed);
		calc_fitness(&locals[i], &seed);
		calc_fitness(&locals[i], &seed);
	}
	if (NUM_OFFSPRING & 0x01) {
		calc_fitness(&locals[NUM_OFFSPRING - 2], &seed);
		calc_fitness(&locals[NUM_OFFSPRING - 2], &seed);
		calc_fitness(&locals[NUM_OFFSPRING - 2], &seed);
	}

	for (i = 0; (i < MAX_GENERATIONS); i++) {
		retVal = 1;
		waitCount = 0;
		while (retVal) {
			if (0 == mutex_lock()) {
				insert_roulette(lock, pool, locals, parents, &seed);
		/*
				if (lock[1]) {
					seeds[th_id] = 43;
					mutex_unlock();
					return;
				}
				
				for (j = 0; j < NUM_OFFSPRING; j++) {
					if (locals[j].fitness >= END_FITNESS) {
						lock[1] = 1;
						seeds[th_id] = 44;
						mutex_unlock();
						return;
					}
				}*/
				seeds[th_id] = waitCount;
				mutex_unlock();
				retVal = 0;
			} else {
				for (j = 0; j < 5000 * grand(&seed); j++) {
					waitCount++;
				}
			}
		}

		for (j = 0; j < NUM_OFFSPRING; j++) {
			create_individual(parents, &locals[j], &seed);
		}
		for (j = 0; j < (NUM_OFFSPRING - 1); j += 2) {
			calc_fitness(&locals[j], &seed);
			calc_fitness(&locals[j], &seed);
			calc_fitness(&locals[j], &seed);
		}
		if (NUM_OFFSPRING & 0x01) {
			calc_fitness(&locals[NUM_OFFSPRING - 2], &seed);
			calc_fitness(&locals[NUM_OFFSPRING - 2], &seed);
			calc_fitness(&locals[NUM_OFFSPRING - 2], &seed);
		}
	}
	seeds[th_id] = i;

	return;
}

__global__ void init_ga(chromo *pool, unsigned *seeds)
{
	int i;
	unsigned seed = seeds[0];
	for (i = 0; i < NUM_INDIVIDUALS; i++) {
		init_individual(&pool[i], &seed);
		if (i & 0x01) {
			calc_fitness(&pool[i - 1], &seed);
			calc_fitness(&pool[i - 1], &seed);
			calc_fitness(&pool[i - 1], &seed);
		}
	}
	seeds[0] = 14;
}

__device__ int insert_roulette(mutex *lock, chromo *pool, chromo *locals, 
									chromo *parents, unsigned *seed)
{
    int fitness_sum;

    fitness_sum = insert(pool, locals);

    roulette(pool, parents, fitness_sum, seed);

	return 0;
}

//this is called by insert_roulette, good for code separation
__device__ int insert(chromo *pool, chromo *locals)
{
    signed int i,j,k;
    int fit_sum = 0;
    int worst[NUM_OFFSPRING];
    int flag;

    for (i = 0; i < NUM_OFFSPRING; i++) {
        worst[i] = 250000;
    }

    for (j = 0; j < NUM_OFFSPRING; j++) {
        fit_sum = 0;
        for (i = 0; i < NUM_INDIVIDUALS; i++) {
            fit_sum += pool[i].fitness;

            if ((worst[j] == 250000) ||
                    (pool[i].fitness < pool[worst[j]].fitness)) {
                flag = 0;
                for (k = j - 1; k >= 0; k--) {
                    if (worst[k] == i) {
                        flag = 1;
                        break;
                    }
                }

                if (!flag) {
                    worst[j] = i;
                }
            }
        }
    }


    for (i = 0; i < NUM_OFFSPRING; i++) {
        for (j = NUM_OFFSPRING; j > 0; j--) {
            if ((pool[worst[j - 1]].fitness < locals[i].fitness)) break;
        }

        if (!j) continue;
        j--;
        for (k = 0; k < j; k++) {
            cpy_ind(&pool[worst[k]], &pool[worst[k + 1]]);
        }

        fit_sum -= pool[worst[j]].fitness;
        cpy_ind(&pool[worst[j]], &locals[i]);
        fit_sum += pool[worst[j]].fitness;
    }

	return fit_sum;
}

//this is called by insert_roulette, good for code separation
__device__ int roulette(chromo *pool, chromo *parents, int sum, unsigned *seed)
{
	int rand_val = (grand(seed) * sum);
    int total_fit = 0;
	int i;

    for (i = 0; i < NUM_INDIVIDUALS - 1; i++) {
        total_fit += pool[i].fitness;
        if (total_fit > rand_val) break;
    }

    cpy_ind(&parents[0], &pool[i]);
    rand_val = (grand(seed) * sum);
    total_fit = 0;

    for (i = 0; i < NUM_INDIVIDUALS - 1; i++) {
        total_fit += pool[i].fitness;
        if (total_fit > rand_val) break;
    }

    cpy_ind(&parents[1], &pool[i]);

    return 0;
}

#include "mutex_testing/mutex_testing.cu"
#include "random.cu"
#include "ind_ga.cu"
#include "main.c"
